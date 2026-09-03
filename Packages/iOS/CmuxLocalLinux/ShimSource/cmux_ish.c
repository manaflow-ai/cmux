// cmux shim over the vendored iSH kernel. Modeled on iSH's own
// app/AppDelegate.m boot path and app/TerminalViewController.m startSession /
// app/Terminal.m pty glue, with the WKWebView terminal replaced by a raw
// byte callback (the bytes feed libghostty via GhosttySurfaceView).
//
// iSH predates a public embedding API. This file is therefore deliberately
// conservative about ownership: all calls into the kernel are serialized at
// the lifecycle boundary, every host-facing tty operation pins its tty, and
// callback state is detached before a session handle can be reused.
#include "cmux_ish.h"

#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/mm.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/tty.h"
#include "tools/fakefs.h"
#include "emu/mmu.h"

// ---- lifecycle and handles -------------------------------------------

#define CMUX_MAX_SESSIONS 64
#define CMUX_SESSION_SLOT_BITS 6u
#define CMUX_SESSION_SLOT_MASK ((uint32_t) CMUX_MAX_SESSIONS - 1u)
// Keep the sign bit clear because the public ABI returns an int. A generation
// is intentionally part of every handle, so a stale handle cannot operate a
// newly opened session that reuses the same table slot.
#define CMUX_HANDLE_MAX_GENERATION ((uint32_t) INT_MAX >> CMUX_SESSION_SLOT_BITS)
#define CMUX_EXEC_BLOB_MAX ((size_t) 32 * PAGE_SIZE)

_Static_assert((CMUX_MAX_SESSIONS & (CMUX_MAX_SESSIONS - 1)) == 0,
               "session slot mask requires a power-of-two table size");

enum cmux_session_state {
    CMUX_SESSION_FREE = 0,
    CMUX_SESSION_OPENING = 1,
    CMUX_SESSION_ACTIVE = 2,
    CMUX_SESSION_CLOSING = 3,
};

struct cmux_session;

// One binding is allocated per open, rather than per table slot. An old tty
// can outlive its public session handle after hangup; a unique binding keeps
// output from that tty from being routed to a later session in the same slot.
struct cmux_session_binding {
    struct cmux_session *session;
    pthread_mutex_t callback_lock;
    pthread_cond_t callback_idle;
    unsigned callbacks_in_flight;
    bool accepting;
    bool ended;
    cmux_ish_output_cb cb;
    void *context;
    cmux_ish_input_ready_cb input_ready_cb;
    void *input_ready_context;
};

struct cmux_session {
    // Accessed atomically by tty cleanup, and under cmux_lock elsewhere.
    _Atomic int state;
    uint32_t generation;
    _Atomic(struct tty *) tty;
    _Atomic(struct cmux_session_binding *) binding;
    int pid;
};

static struct cmux_session sessions[CMUX_MAX_SESSIONS];
static pthread_mutex_t cmux_lock = PTHREAD_MUTEX_INITIALIZER;
// Protects the tty-to-binding side table while a kernel write is obtaining a
// binding. iSH's struct tty has a union for `pty` metadata and `data`.
// pty_open_fake calls pty_slave_init_inode after the driver's init callback,
// so storing a binding in tty->data would overwrite it with uid/gid/perms.
// Callback users are counted by the binding lock before this read lock is
// released.
static pthread_rwlock_t cmux_binding_rwlock = PTHREAD_RWLOCK_INITIALIZER;
// fakefs import and boot both mutate iSH's process/mount globals. Keep these
// operations mutually exclusive, but do not hold cmux_lock while entering iSH
// (iSH may acquire ttys_lock and mounts_lock).
static pthread_mutex_t cmux_boot_lock = PTHREAD_MUTEX_INITIALIZER;
// iSH has no supported API for constructing several host-created tasks at
// once. Serialize become_new_init_child through exec/task_start while still
// allowing input, output, resize, and exit callbacks to run concurrently.
static pthread_mutex_t cmux_spawn_lock = PTHREAD_MUTEX_INITIALIZER;

enum cmux_boot_state {
    CMUX_BOOT_UNINITIALIZED = 0,
    CMUX_BOOTING = 1,
    CMUX_BOOTED = 2,
    CMUX_BOOT_FAILED = 3,
};
static enum cmux_boot_state cmux_boot_state = CMUX_BOOT_UNINITIALIZED;
static int cmux_boot_error = _EIO;

// iSH calls exit_hook while holding pids_lock, immediately before the task
// is destroyed. Keep and chain a pre-existing hook because another embedding
// layer may have installed one before this shim boots.
static void (*cmux_previous_exit_hook)(struct task *task, int code);
static bool cmux_exit_hook_installed;

// The binding is kept outside struct tty because iSH overlays pty inode
// metadata and the old `data` field in one union. Entries are allocated for a
// session and removed before their binding is freed. The read side is held
// while a writer increments callbacks_in_flight; the write side is held while
// an entry is detached and its callback is drained.
struct cmux_tty_binding_entry {
    struct tty *tty;
    struct cmux_session_binding *binding;
    struct cmux_tty_binding_entry *next;
};
static struct cmux_tty_binding_entry *cmux_tty_bindings;

// ---- callback binding -------------------------------------------------

static struct cmux_session_binding *cmux_binding_create(struct cmux_session *session,
                                                         cmux_ish_output_cb cb,
                                                         void *context,
                                                         cmux_ish_input_ready_cb input_ready_cb,
                                                         void *input_ready_context) {
    struct cmux_session_binding *binding = calloc(1, sizeof(*binding));
    if (binding == NULL)
        return NULL;
    if (pthread_mutex_init(&binding->callback_lock, NULL) != 0) {
        free(binding);
        return NULL;
    }
    if (pthread_cond_init(&binding->callback_idle, NULL) != 0) {
        pthread_mutex_destroy(&binding->callback_lock);
        free(binding);
        return NULL;
    }
    binding->session = session;
    binding->accepting = true;
    binding->cb = cb;
    binding->context = context;
    binding->input_ready_cb = input_ready_cb;
    binding->input_ready_context = input_ready_cb != NULL ? input_ready_context : NULL;
    return binding;
}

// Stop ordinary output and wait for callbacks already in flight. The callback
// pointer remains available until cmux_binding_finish() sends the terminal
// event, so a retained context can be released by that event rather than by a
// racy host-side guess about whether the process exited first.
static void cmux_binding_stop_output(struct cmux_session_binding *binding) {
    if (binding == NULL)
        return;
    pthread_mutex_lock(&binding->callback_lock);
    binding->accepting = false;
    while (binding->callbacks_in_flight != 0)
        pthread_cond_wait(&binding->callback_idle, &binding->callback_lock);
    pthread_mutex_unlock(&binding->callback_lock);
}

// Deliver the one-shot terminal event. This function is synchronous with
// respect to the callback, and is safe when natural process exit races an
// explicit hangup. Callers must not invoke the C shim synchronously from the
// callback, because iSH may be holding ttys_lock or pids_lock here.
static void cmux_binding_finish(struct cmux_session_binding *binding) {
    if (binding == NULL)
        return;

    cmux_ish_output_cb cb = NULL;
    void *context = NULL;
    pthread_mutex_lock(&binding->callback_lock);
    binding->accepting = false;
    while (binding->callbacks_in_flight != 0)
        pthread_cond_wait(&binding->callback_idle, &binding->callback_lock);
    if (!binding->ended) {
        binding->ended = true;
        binding->input_ready_cb = NULL;
        binding->input_ready_context = NULL;
        cb = binding->cb;
        context = binding->context;
        // Reserve one in-flight slot while invoking the terminal callback.
        // This makes a concurrent finish caller wait and then observe ended.
        if (cb != NULL)
            binding->callbacks_in_flight++;
    }
    pthread_mutex_unlock(&binding->callback_lock);

    if (cb == NULL) {
        // There is no host callback to notify, but clear the borrowed pointer
        // so an accidental later writer cannot observe stale context.
        pthread_mutex_lock(&binding->callback_lock);
        binding->cb = NULL;
        binding->context = NULL;
        binding->input_ready_cb = NULL;
        binding->input_ready_context = NULL;
        pthread_mutex_unlock(&binding->callback_lock);
        return;
    }

    cb(context, NULL, 0);

    pthread_mutex_lock(&binding->callback_lock);
    binding->cb = NULL;
    binding->context = NULL;
    binding->input_ready_cb = NULL;
    binding->input_ready_context = NULL;
    if (--binding->callbacks_in_flight == 0)
        pthread_cond_broadcast(&binding->callback_idle);
    pthread_mutex_unlock(&binding->callback_lock);
}

// Abort is used only for an open that failed before it became ACTIVE. No
// terminal event is emitted in that case, so the caller still owns context.
static void cmux_binding_abort(struct cmux_session_binding *binding) {
    if (binding == NULL)
        return;
    cmux_binding_stop_output(binding);
    pthread_mutex_lock(&binding->callback_lock);
    binding->ended = true;
    binding->cb = NULL;
    binding->context = NULL;
    binding->input_ready_cb = NULL;
    binding->input_ready_context = NULL;
    pthread_mutex_unlock(&binding->callback_lock);
}

static void cmux_binding_destroy(struct cmux_session_binding *binding, bool notify_end) {
    if (binding == NULL)
        return;
    if (notify_end)
        cmux_binding_finish(binding);
    else
        cmux_binding_abort(binding);
    pthread_cond_destroy(&binding->callback_idle);
    pthread_mutex_destroy(&binding->callback_lock);
    free(binding);
}

// Find an entry while cmux_binding_rwlock is held for reading or writing.
// The returned pointer is borrowed and must not outlive that lock.
static struct cmux_tty_binding_entry *cmux_tty_binding_find_locked(
    struct tty *tty) {
    for (struct cmux_tty_binding_entry *entry = cmux_tty_bindings;
         entry != NULL; entry = entry->next) {
        if (entry->tty == tty)
            return entry;
    }
    return NULL;
}

// Install the side-table association after pty_open_fake has finished its
// pty_slave_init_inode call. That call writes the pty uid/gid/perms union
// fields and would otherwise clobber a value stored in tty->data.
static int cmux_tty_binding_insert(struct tty *tty,
                                   struct cmux_session_binding *binding) {
    if (tty == NULL || binding == NULL)
        return _EINVAL;
    struct cmux_tty_binding_entry *entry = calloc(1, sizeof(*entry));
    if (entry == NULL)
        return _ENOMEM;
    entry->tty = tty;
    entry->binding = binding;

    pthread_rwlock_wrlock(&cmux_binding_rwlock);
    if (cmux_tty_binding_find_locked(tty) != NULL) {
        pthread_rwlock_unlock(&cmux_binding_rwlock);
        free(entry);
        return _EEXIST;
    }
    entry->next = cmux_tty_bindings;
    cmux_tty_bindings = entry;
    pthread_rwlock_unlock(&cmux_binding_rwlock);
    return 0;
}

// Which field of a side-table entry a detach operation matches on.
enum cmux_binding_key {
    CMUX_BINDING_KEY_TTY,
    CMUX_BINDING_KEY_BINDING,
    CMUX_BINDING_KEY_SESSION,
};

static bool cmux_tty_binding_entry_matches(const struct cmux_tty_binding_entry *entry,
                                           enum cmux_binding_key key,
                                           const void *value) {
    switch (key) {
    case CMUX_BINDING_KEY_TTY:
        return entry->tty == value;
    case CMUX_BINDING_KEY_BINDING:
        // Pointer equality is sufficient here because the binding remains
        // allocated as long as its side-table entry exists, so malloc cannot
        // recycle its address.
        return entry->binding == value;
    case CMUX_BINDING_KEY_SESSION:
        // Defensive fallback for a cleanup path that clears session->binding
        // before removing the side-table node. Matching by session makes a
        // stale node recoverable without dereferencing a freed binding.
        return entry->binding != NULL && entry->binding->session == value;
    }
    return false;
}

// Unlink and return the first entry matching `key`/`value` while the write
// lock is held. The caller owns the returned node and must destroy its binding
// before releasing the lock. Returns NULL when nothing matches.
static struct cmux_tty_binding_entry *cmux_tty_binding_detach_locked(
    enum cmux_binding_key key, const void *value) {
    if (value == NULL)
        return NULL;
    struct cmux_tty_binding_entry **cursor = &cmux_tty_bindings;
    while (*cursor != NULL) {
        if (cmux_tty_binding_entry_matches(*cursor, key, value)) {
            struct cmux_tty_binding_entry *entry = *cursor;
            *cursor = entry->next;
            entry->next = NULL;
            return entry;
        }
        cursor = &(*cursor)->next;
    }
    return NULL;
}

// Detach the entry owned by `session`, preferring its published binding and
// falling back to a session scan for a node left behind by an unusual kernel
// error path. Both branches unlink the node, so the caller may free it.
static struct cmux_tty_binding_entry *cmux_tty_binding_detach_session_locked(
    struct cmux_session *session, struct cmux_session_binding *published) {
    struct cmux_tty_binding_entry *entry =
        cmux_tty_binding_detach_locked(CMUX_BINDING_KEY_BINDING, published);
    if (entry == NULL)
        entry = cmux_tty_binding_detach_locked(CMUX_BINDING_KEY_SESSION, session);
    return entry;
}

// Roll back a binding after session construction fails. The side-table write
// lock is required here even though the task has not started: a tty reference
// can be released by fdtable rollback, and its cleanup callback may otherwise
// race this exchange and leave a freed binding reachable from the table.
// It leaves the session slot FREE and destroys the binding that this caller
// still owns. If tty cleanup already detached the binding, this is a no-op.
static void cmux_abort_session_binding(struct cmux_session *session) {
    if (session == NULL)
        return;

    struct cmux_session_binding *binding_to_destroy = NULL;
    pthread_rwlock_wrlock(&cmux_binding_rwlock);
    pthread_mutex_lock(&cmux_lock);

    struct cmux_session_binding *published = atomic_load_explicit(
        &session->binding, memory_order_acquire);
    struct cmux_tty_binding_entry *entry =
        cmux_tty_binding_detach_session_locked(session, published);
    if (entry != NULL) {
        binding_to_destroy = entry->binding;
        struct tty *entry_tty = entry->tty;
        free(entry);

        struct cmux_session_binding *expected = binding_to_destroy;
        bool owned = atomic_compare_exchange_strong_explicit(
            &session->binding, &expected, NULL,
            memory_order_acq_rel, memory_order_acquire);
        if (!owned && expected != NULL) {
            // A different binding cannot be valid while this session is
            // OPENING. Keep the public pointer intact and let its owner
            // handle it; do not destroy memory that we did not detach.
            binding_to_destroy = NULL;
        }

        struct tty *expected_tty = entry_tty;
        (void) atomic_compare_exchange_strong_explicit(
            &session->tty, &expected_tty, NULL,
            memory_order_acq_rel, memory_order_acquire);
    } else {
        // pty_open_fake can fail before the side-table insertion. In that
        // case the binding is still owned directly by the session slot.
        binding_to_destroy = atomic_exchange_explicit(
            &session->binding, NULL, memory_order_acq_rel);
        atomic_store_explicit(&session->tty, NULL, memory_order_release);
    }

    session->pid = -1;
    atomic_store_explicit(&session->state, CMUX_SESSION_FREE, memory_order_release);
    pthread_mutex_unlock(&cmux_lock);

    if (binding_to_destroy != NULL)
        cmux_binding_destroy(binding_to_destroy, false);
    pthread_rwlock_unlock(&cmux_binding_rwlock);
}

static int cmux_tty_init(struct tty *tty);
static int cmux_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking);
static void cmux_tty_cleanup(struct tty *tty);
static void cmux_tty_input_consumed(struct tty *tty);

static struct tty_driver_ops cmux_tty_ops = {
    .init = cmux_tty_init,
    .write = cmux_tty_write,
    .cleanup = cmux_tty_cleanup,
};
// pty_open_fake overwrites ttys/limit/major with the pty-slave table; this
// declaration only carries the ops (same shape as iSH's ios_pty_driver).
static struct tty_driver cmux_pty_driver = {.ops = &cmux_tty_ops};

// iSH's tty_hangup marks the tty and wakes readers, but does not send the
// POSIX SIGHUP/SIGCONT pair itself. Capture the foreground process group while
// holding the tty lock, then signal it after unlocking because signal delivery
// takes pids_lock.
static void cmux_hangup_tty(struct tty *tty) {
    if (tty == NULL)
        return;
    pid_t_ foreground_group;
    lock(&tty->lock);
    foreground_group = tty->fg_group;
    tty_hangup(tty);
    unlock(&tty->lock);
    if (foreground_group != 0) {
        (void) send_group_signal(foreground_group, SIGHUP_, SIGINFO_NIL);
        (void) send_group_signal(foreground_group, SIGCONT_, SIGINFO_NIL);
    }
}

// Console for the init process: accept and discard writes.
static int cmux_console_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) tty;
    (void) buf;
    (void) blocking;
    if (len > (size_t) INT_MAX)
        return _EOVERFLOW;
    return (int) len;
}
static struct tty_driver_ops cmux_console_ops = {
    .write = cmux_console_write,
};
DEFINE_TTY_DRIVER(cmux_console_driver, &cmux_console_ops, TTY_CONSOLE_MAJOR, 64);

static int cmux_tty_init(struct tty *tty) {
    // Called with ttys_lock held from tty_get. Do not use tty->data here:
    // pty_open_fake invokes pty_slave_init_inode immediately after this
    // callback, and that function writes the overlapping pty metadata union.
    // The session/tty association is installed by session_open after
    // pty_open_fake returns.
    // tty_alloc leaves the union uninitialized. Clear it before the pty
    // metadata callback so an accidental slave-side ioctl never follows a
    // garbage `pty.other` pointer.
    if (tty != NULL)
        memset(&tty->pty, 0, sizeof(tty->pty));
    return 0;
}

static int cmux_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) blocking;
    if (len > (size_t) INT_MAX)
        return _EOVERFLOW;

    pthread_rwlock_rdlock(&cmux_binding_rwlock);
    struct cmux_tty_binding_entry *entry = cmux_tty_binding_find_locked(tty);
    struct cmux_session_binding *binding = entry != NULL ? entry->binding : NULL;
    if (binding == NULL || len == 0) {
        pthread_rwlock_unlock(&cmux_binding_rwlock);
        return (int) len;
    }

    // Do not hold callback_lock while invoking host code. In particular, the
    // Swift callback may enqueue work that eventually calls hangup.
    pthread_mutex_lock(&binding->callback_lock);
    if (!binding->accepting || binding->cb == NULL) {
        pthread_mutex_unlock(&binding->callback_lock);
        pthread_rwlock_unlock(&cmux_binding_rwlock);
        return (int) len;
    }
    cmux_ish_output_cb cb = binding->cb;
    void *context = binding->context;
    binding->callbacks_in_flight++;
    pthread_mutex_unlock(&binding->callback_lock);
    // The in-flight count now keeps the binding alive after this read lock is
    // released. tty cleanup takes the write lock and waits for that count.
    pthread_rwlock_unlock(&cmux_binding_rwlock);

    cb(context, buf, len);

    pthread_mutex_lock(&binding->callback_lock);
    if (--binding->callbacks_in_flight == 0)
        pthread_cond_broadcast(&binding->callback_idle);
    pthread_mutex_unlock(&binding->callback_lock);
    return (int) len;
}

// Notify a host that at least one byte was removed from the tty input buffer.
// `tty_notify_consumed` invokes this while tty->lock is held. Pin the binding
// under the side-table read lock, increment its in-flight count, then release
// all shim-owned locks before invoking the host signal. The vendor tty lock is
// still held by the caller, so the host callback must remain non-blocking and
// must not call back into iSH synchronously.
static void cmux_tty_input_consumed(struct tty *tty) {
    if (tty == NULL)
        return;

    pthread_rwlock_rdlock(&cmux_binding_rwlock);
    struct cmux_tty_binding_entry *entry = cmux_tty_binding_find_locked(tty);
    struct cmux_session_binding *binding = entry != NULL ? entry->binding : NULL;
    if (binding == NULL) {
        pthread_rwlock_unlock(&cmux_binding_rwlock);
        return;
    }

    pthread_mutex_lock(&binding->callback_lock);
    if (!binding->accepting || binding->input_ready_cb == NULL) {
        pthread_mutex_unlock(&binding->callback_lock);
        pthread_rwlock_unlock(&cmux_binding_rwlock);
        return;
    }
    cmux_ish_input_ready_cb cb = binding->input_ready_cb;
    void *context = binding->input_ready_context;
    binding->callbacks_in_flight++;
    pthread_mutex_unlock(&binding->callback_lock);
    // The in-flight count keeps the binding alive after this read lock is
    // released. Cleanup/hangup waits for this callback before destroying it.
    pthread_rwlock_unlock(&cmux_binding_rwlock);

    cb(context);

    pthread_mutex_lock(&binding->callback_lock);
    if (--binding->callbacks_in_flight == 0)
        pthread_cond_broadcast(&binding->callback_idle);
    pthread_mutex_unlock(&binding->callback_lock);
}

static void cmux_tty_cleanup(struct tty *tty) {
    // tty_release invokes cleanup while holding ttys_lock and tty->lock. No
    // cmux_lock is taken until after the side-table entry is detached and all
    // host callbacks have drained. This preserves the lock order used by host
    // calls that pin a tty before looking up a session.
    // Block new writers while detaching the side-table entry. This also
    // covers the tty_write path, which can invoke this driver's write callback
    // after dropping tty->lock. tty->data is reserved for iSH's pty metadata.
    // Prevent a read that starts after cleanup begins from trying to notify a
    // binding that is about to be detached. `tty_release` holds tty->lock here,
    // so no concurrent tty_read can be inside tty_read_into_buf.
    tty->input_consumed_callback = NULL;
    pthread_rwlock_wrlock(&cmux_binding_rwlock);
    struct cmux_tty_binding_entry *entry =
        cmux_tty_binding_detach_locked(CMUX_BINDING_KEY_TTY, tty);
    if (entry == NULL) {
        pthread_rwlock_unlock(&cmux_binding_rwlock);
        return;
    }
    struct cmux_session_binding *binding = entry->binding;
    free(entry);

    struct cmux_session *session = binding->session;
    int state = atomic_load_explicit(&session->state, memory_order_acquire);
    struct tty *expected_tty = tty;
    atomic_compare_exchange_strong_explicit(&session->tty, &expected_tty, NULL,
                                            memory_order_acq_rel,
                                            memory_order_acquire);
    struct cmux_session_binding *expected_binding = binding;
    bool owns_session = atomic_compare_exchange_strong_explicit(
        &session->binding, &expected_binding, NULL,
        memory_order_acq_rel, memory_order_acquire);

    // A process can exit without the host explicitly hanging it up. Deliver
    // the terminal event for ACTIVE/CLOSING sessions. Do not send it for an
    // OPENING rollback, because the caller still owns that context when open
    // returns an error. If a stale binding loses the session race, abort it
    // without notifying a context that may now belong to another owner.
    bool notify_end = owns_session && state != CMUX_SESSION_OPENING;
    cmux_binding_destroy(binding, notify_end);
    if (owns_session && state != CMUX_SESSION_OPENING) {
        // Publish FREE while holding cmux_lock. Session open scans this state
        // before assigning a new generation; publishing it without the lock
        // allowed a stale host operation to observe a half-retired slot.
        pthread_mutex_lock(&cmux_lock);
        if (atomic_load_explicit(&session->binding, memory_order_acquire) == NULL)
            atomic_store_explicit(&session->state, CMUX_SESSION_FREE, memory_order_release);
        pthread_mutex_unlock(&cmux_lock);
    }
    pthread_rwlock_unlock(&cmux_binding_rwlock);
}

// iSH invokes this hook for a task group after its file descriptors have been
// closed, but before the task is destroyed. Normally cmux_tty_cleanup has
// already emitted the terminal event. The hook is a fallback for a process
// that still owns a tty reference through its process group, and also covers
// unusual exit paths that do not reach the driver's final cleanup.
static void cmux_exit_hook(struct task *task, int code) {
    struct cmux_session *session_for_binding = NULL;
    struct cmux_tty_binding_entry *entry = NULL;
    struct cmux_session_binding *binding = NULL;

    // Take the write side before looking up the entry. This gives the hook
    // exclusive ownership of the side-table node while it emits the terminal
    // event and frees the binding. It also prevents a tty writer from holding
    // a stale binding pointer after this function returns.
    pthread_rwlock_wrlock(&cmux_binding_rwlock);
    pthread_mutex_lock(&cmux_lock);
    if (task != NULL) {
        // exit_hook runs for the final thread in a task group. That thread is
        // not necessarily the session leader, so match the stable tgid.
        int leader_pid = (int) task->tgid;
        if (leader_pid == 1) {
            // iSH's init-exit path shuts down every task and unmounts the
            // process-global kernel. Prevent later session opens from reaching
            // become_new_init_child's assertion after that shutdown.
            cmux_boot_state = CMUX_BOOT_FAILED;
            cmux_boot_error = _ESRCH;
        }
        for (int i = 0; i < CMUX_MAX_SESSIONS; i++) {
            struct cmux_session *session = &sessions[i];
            int state = atomic_load_explicit(&session->state, memory_order_acquire);
            if ((state == CMUX_SESSION_ACTIVE || state == CMUX_SESSION_CLOSING) &&
                session->pid == leader_pid) {
                session_for_binding = session;
                if (state == CMUX_SESSION_ACTIVE)
                    atomic_store_explicit(&session->state, CMUX_SESSION_CLOSING,
                                          memory_order_release);
                binding = atomic_load_explicit(&session->binding, memory_order_acquire);
                entry = cmux_tty_binding_detach_session_locked(session, binding);
                break;
            }
        }
    }
    if (entry != NULL) {
        binding = entry->binding;
        struct tty *entry_tty = entry->tty;
        free(entry);
        // Detach the public handle before invoking host code. Input and
        // resize calls that arrive concurrently now fail with EBADF rather
        // than racing a binding that is being retired.
        struct cmux_session_binding *expected_binding = binding;
        bool detached = atomic_compare_exchange_strong_explicit(
            &session_for_binding->binding, &expected_binding, NULL,
            memory_order_acq_rel, memory_order_acquire);
        if (detached) {
            struct tty *expected_tty = entry_tty;
            atomic_compare_exchange_strong_explicit(
                &session_for_binding->tty, &expected_tty, NULL,
                memory_order_acq_rel, memory_order_acquire);
        }
        // A concurrent cleanup or a slot reuse can make the CAS fail. The
        // side-table entry still owns this binding, so it must be destroyed
        // either way. A failed CAS only means that the session now points at
        // a different binding; the state check below leaves that new session
        // untouched.
        (void) detached;
    } else if (session_for_binding != NULL) {
        // tty cleanup may have removed and destroyed the binding first. It
        // also clears session->binding, so this path never dereferences an
        // unknown pointer. A side-table node left by an unusual kernel error
        // is recovered by the session scan below before reaching this branch.
        binding = NULL;
    }
    pthread_mutex_unlock(&cmux_lock);

    if (binding != NULL)
        cmux_binding_destroy(binding, true);

    if (session_for_binding != NULL) {
        pthread_mutex_lock(&cmux_lock);
        if (atomic_load_explicit(&session_for_binding->state, memory_order_acquire) ==
                CMUX_SESSION_CLOSING &&
            atomic_load_explicit(&session_for_binding->binding, memory_order_acquire) == NULL) {
            atomic_store_explicit(&session_for_binding->state, CMUX_SESSION_FREE,
                                  memory_order_release);
        }
        pthread_mutex_unlock(&cmux_lock);
    }
    pthread_rwlock_unlock(&cmux_binding_rwlock);

    // iSH's hook is process-global. Preserve a hook installed by another
    // embedding layer, while avoiding recursion if it points back to ours.
    if (cmux_previous_exit_hook != NULL && cmux_previous_exit_hook != cmux_exit_hook)
        cmux_previous_exit_hook(task, code);
}

static void cmux_install_exit_hook(void) {
    if (cmux_exit_hook_installed)
        return;
    cmux_previous_exit_hook = exit_hook;
    exit_hook = cmux_exit_hook;
    cmux_exit_hook_installed = true;
}

// ---- argument and handle helpers -------------------------------------

static bool cmux_bounded_strlen(const char *value, size_t *length_out) {
    if (value == NULL)
        return false;
    for (size_t i = 0; i < CMUX_EXEC_BLOB_MAX; i++) {
        if (value[i] == '\0') {
            *length_out = i;
            return true;
        }
    }
    return false;
}

// Packs a host pointer vector into iSH's NUL-separated exec blob. The old
// implementation silently truncated at 4096 bytes, which could make do_execve
// walk past the buffer when it counted the supplied strings. Rejecting an
// oversized vector is both safer and consistent with iSH's ARGV_MAX limit.
static int cmux_pack_vector(const char *const *items, bool default_term,
                            char **blob_out, size_t *count_out) {
    if (blob_out == NULL || count_out == NULL)
        return _EINVAL;
    *blob_out = NULL;
    *count_out = 0;

    const char *default_items[] = {"TERM=xterm-256color", NULL};
    if (items == NULL) {
        if (!default_term)
            return _EINVAL;
        items = default_items;
    }

    // Build the blob in one pass. Besides avoiding an extra unbounded strlen,
    // this snapshots each entry before the next entry is inspected and keeps
    // the allocation exact enough for iSH's argv/envp walker.
    char *blob = NULL;
    size_t capacity = 0;
    size_t used = 0;
    size_t count = 0;
    for (const char *const *item = items; *item != NULL; item++) {
        size_t length = 0;
        if (!cmux_bounded_strlen(*item, &length))
            goto too_big;
        // Leave room for this string's NUL and the final empty-string
        // terminator. Check the subtraction's precondition first to avoid a
        // size_t wrap when a vector exactly fills the limit.
        if (used >= CMUX_EXEC_BLOB_MAX - 1 ||
            length > CMUX_EXEC_BLOB_MAX - used - 2)
            goto too_big;

        size_t needed = used + length + 2;
        if (needed > capacity) {
            size_t new_capacity = capacity == 0 ? 64 : capacity * 2;
            if (new_capacity < needed)
                new_capacity = needed;
            if (new_capacity > CMUX_EXEC_BLOB_MAX)
                new_capacity = CMUX_EXEC_BLOB_MAX;
            char *new_blob = realloc(blob, new_capacity);
            if (new_blob == NULL)
                goto out_of_memory;
            blob = new_blob;
            capacity = new_capacity;
        }
        memcpy(blob + used, *item, length);
        blob[used + length] = '\0';
        used += length + 1;
        count++;
    }

    if (blob == NULL) {
        blob = malloc(1);
        if (blob == NULL)
            return _ENOMEM;
    }
    blob[used] = '\0';
    *blob_out = blob;
    *count_out = count;
    return 0;

too_big:
    free(blob);
    return _E2BIG;
out_of_memory:
    free(blob);
    return _ENOMEM;
}

static int cmux_pack_args(const char *const *argv, char **blob_out, size_t *count_out) {
    if (argv == NULL || argv[0] == NULL || argv[0][0] == '\0')
        return _EINVAL;
    return cmux_pack_vector(argv, false, blob_out, count_out);
}

static int cmux_pack_env(const char *const *envp, char **blob_out, size_t *count_out) {
    // A NULL environment means the documented default TERM entry. An
    // explicitly empty vector remains an empty environment.
    if (envp == NULL)
        return cmux_pack_vector(NULL, true, blob_out, count_out);
    return cmux_pack_vector(envp, false, blob_out, count_out);
}

static uint32_t cmux_next_generation(const struct cmux_session *session) {
    if (session->generation >= CMUX_HANDLE_MAX_GENERATION)
        return 0; // Never wrap and make an old opaque handle valid again.
    return session->generation + 1u;
}

static int cmux_encode_handle(int slot, uint32_t generation) {
    uint32_t token = (generation << CMUX_SESSION_SLOT_BITS) | (uint32_t) slot;
    if (token > (uint32_t) INT_MAX)
        return -1;
    return (int) token;
}

static struct cmux_session *cmux_session_lookup_locked(int handle, int *slot_out) {
    if (handle < 0)
        return NULL;
    uint32_t token = (uint32_t) handle;
    int slot = (int) (token & CMUX_SESSION_SLOT_MASK);
    uint32_t generation = token >> CMUX_SESSION_SLOT_BITS;
    if (slot < 0 || slot >= CMUX_MAX_SESSIONS || generation == 0)
        return NULL;
    struct cmux_session *session = &sessions[slot];
    if (session->generation != generation)
        return NULL;
    if (atomic_load_explicit(&session->state, memory_order_acquire) == CMUX_SESSION_FREE)
        return NULL;
    if (slot_out != NULL)
        *slot_out = slot;
    return session;
}

// Pin a tty while the caller performs a host-facing operation. tty_release
// requires ttys_lock, and taking it before cmux_lock also matches iSH's own
// tty lock ordering. The returned reference must be released with
// cmux_release_tty.
static struct tty *cmux_retain_tty_locked(int handle, bool include_closing,
                                          struct cmux_session **session_out) {
    struct tty *tty = NULL;
    struct cmux_session *session = NULL;
    uint32_t generation = 0;
    int expected_state = CMUX_SESSION_FREE;

    // The caller owns ttys_lock. Read the session association under
    // cmux_lock, then release it before waiting for tty->lock. Holding both
    // locks here can deadlock with an iSH writer that holds tty->lock while
    // waiting for a binding reader, and with exit_hook waiting for cmux_lock.
    pthread_mutex_lock(&cmux_lock);
    session = cmux_session_lookup_locked(handle, NULL);
    if (session != NULL) {
        int state = atomic_load_explicit(&session->state, memory_order_acquire);
        if (state != CMUX_SESSION_ACTIVE && !(include_closing && state == CMUX_SESSION_CLOSING))
            session = NULL;
        else
            expected_state = state;
    }
    if (session != NULL) {
        generation = session->generation;
        tty = atomic_load_explicit(&session->tty, memory_order_acquire);
    }
    pthread_mutex_unlock(&cmux_lock);

    if (tty != NULL) {
        // ttys_lock prevents tty_release from freeing this object while we
        // pin it. Do not hold cmux_lock while waiting for the tty lock.
        struct tty *candidate = tty;
        lock(&candidate->lock);
        bool can_use = candidate->refcount != 0 && !candidate->hung_up;
        if (can_use)
            candidate->refcount++;
        unlock(&candidate->lock);
        if (!can_use)
            tty = NULL;

        if (tty != NULL) {
            // A concurrent hangup or natural exit may have retired and
            // reused the session slot while tty->lock was held. Revalidate
            // the generation and pointer before exposing the pin. The old
            // tty remains safe because ttys_lock is still held.
            pthread_mutex_lock(&cmux_lock);
            bool valid = session != NULL && session->generation == generation &&
                atomic_load_explicit(&session->state, memory_order_acquire) == expected_state &&
                atomic_load_explicit(&session->tty, memory_order_acquire) == tty;
            if (!valid) {
                pthread_mutex_unlock(&cmux_lock);
                tty_release(tty);
                tty = NULL;
                session = NULL;
            } else {
                pthread_mutex_unlock(&cmux_lock);
            }
        }
    }

    if (session_out != NULL)
        *session_out = session;
    return tty;
}

static struct tty *cmux_retain_tty(int handle, bool include_closing,
                                   struct cmux_session **session_out) {
    lock(&ttys_lock);
    struct tty *tty = cmux_retain_tty_locked(handle, include_closing, session_out);
    unlock(&ttys_lock);
    return tty;
}

static void cmux_release_tty(struct tty *tty) {
    if (tty == NULL)
        return;
    lock(&ttys_lock);
    tty_release(tty);
    unlock(&ttys_lock);
}

// A few iSH do_execve error returns bypass elf_exec's normal write-lock
// cleanup. Such a return is possible before an unstarted task is discarded,
// and mem_destroy would otherwise try to acquire the same lock forever. Only
// unlock when this host thread still owns the task, so a procfs reader cannot
// be mistaken for the owner of an unrelated lock.
static void cmux_unlock_unstarted_exec_mm(struct task *task) {
    if (task == NULL || current != task || task->mm == NULL || IS_ERR(task->mm))
        return;
    if (atomic_load_explicit(&task->mm->mem.lock.val, memory_order_acquire) == -1)
        write_wrunlock(&task->mm->mem.lock);
}

// Discard a task that was constructed but never started. iSH exposes no
// rollback API for become_new_init_child, so mirror do_exit's resource release
// while the task is still private to this thread. This path is only used for
// validation/exec failures before task_start.
static void cmux_discard_unstarted_task(struct task *task) {
    if (task == NULL)
        return;

    // Keep this helper safe for callers that have not cleared current yet.
    cmux_unlock_unstarted_exec_mm(task);

    if (task->files != NULL && !IS_ERR(task->files)) {
        fdtable_release(task->files);
        task->files = NULL;
    }
    if (task->fs != NULL && !IS_ERR(task->fs)) {
        // construct_task returns an ERR_PTR encoded in fs->root when opening
        // the initial working directory fails. fs_info_release assumes both
        // fields are real fd pointers, so clear those sentinels first.
        if (IS_ERR(task->fs->root))
            task->fs->root = NULL;
        if (IS_ERR(task->fs->pwd))
            task->fs->pwd = NULL;
        fs_info_release(task->fs);
        task->fs = NULL;
    }
    if (task->mm != NULL && !IS_ERR(task->mm)) {
        mm_release(task->mm);
        task->mm = NULL;
    }
    if (task->sighand != NULL && !IS_ERR(task->sighand)) {
        sighand_release(task->sighand);
        task->sighand = NULL;
    }

    lock(&pids_lock);
    struct tgroup *group = task->group;
    if (group != NULL && !IS_ERR(group)) {
        lock(&group->lock);
        if (group->tty != NULL) {
            // The init rollback can own the console tty. iSH documents that
            // task_leave_session needs both locks, so keep this branch for
            // that path. A newly constructed child has no controlling tty;
            // avoid the helper there because it takes ttys_lock while
            // pids_lock is held, which would invert the tty_open order.
            task_leave_session(task);
        } else {
            list_remove_safe(&group->session);
        }
        unlock(&group->lock);
        list_remove_safe(&task->group_links);
        list_remove_safe(&group->pgroup);
    }
    list_remove_safe(&task->siblings);
    struct pid *pid = pid_get((dword_t) task->pid);
    if (pid != NULL && pid->task == task)
        pid->task = NULL;
    unlock(&pids_lock);

    // A malformed ERR_PTR group can only come from an upstream allocation
    // failure. Never pass that sentinel to cond_destroy/free.
    if (group != NULL && !IS_ERR(group)) {
        cond_destroy(&group->child_exit);
        cond_destroy(&group->stopped_cond);
        free(group);
    }
    cond_destroy(&task->pause);
    cond_destroy(&task->ptrace.cond);
    free(task);
}

static void cmux_remove_mount(const char *point) {
    lock(&mounts_lock);
    struct mount *mount = NULL;
    struct mount *candidate;
    list_for_each_entry(&mounts, candidate, mounts) {
        if (strcmp(candidate->point, point) == 0) {
            mount = candidate;
            break;
        }
    }
    if (mount != NULL && mount->refcount == 0)
        mount_remove(mount);
    unlock(&mounts_lock);
}

// ---- rootfs import ----------------------------------------------------

// Formats a NUL-terminated diagnostic into the caller's buffer. A NULL or
// empty buffer is accepted so every failure site can call this unconditionally.
__attribute__((format(printf, 3, 4)))
static void cmux_write_error(char *err_out, size_t err_len, const char *format, ...) {
    if (err_out == NULL || err_len == 0)
        return;
    va_list args;
    va_start(args, format);
    (void) vsnprintf(err_out, err_len, format, args);
    va_end(args);
    err_out[err_len - 1] = '\0';
}

static bool cmux_path_fits_ish(const char *path) {
    size_t length = 0;
    // fakefs_import appends `/data` and `/meta.db`, while mount_root resolves
    // into iSH's MAX_PATH-sized buffer. Leave a small suffix margin so neither
    // helper silently truncates a host path.
    return cmux_bounded_strlen(path, &length) &&
           length < (size_t) MAX_PATH - 16;
}

bool cmux_ish_import_rootfs(const char *tar_gz_path, const char *dest_dir,
                            char *err_out, size_t err_len) {
    cmux_write_error(err_out, err_len, "%s", "");
    if (tar_gz_path == NULL || dest_dir == NULL || tar_gz_path[0] == '\0' ||
        dest_dir[0] == '\0' || !cmux_path_fits_ish(tar_gz_path) ||
        !cmux_path_fits_ish(dest_dir)) {
        cmux_write_error(err_out, err_len, "invalid rootfs path (errno=%d)", -_EINVAL);
        return false;
    }

    pthread_mutex_lock(&cmux_boot_lock);
    pthread_mutex_lock(&cmux_lock);
    enum cmux_boot_state state = cmux_boot_state;
    pthread_mutex_unlock(&cmux_lock);
    if (state != CMUX_BOOT_UNINITIALIZED) {
        cmux_write_error(err_out, err_len, "kernel is already initialized (state=%d)",
                         (int) state);
        pthread_mutex_unlock(&cmux_boot_lock);
        return false;
    }

    struct fakefsify_error fs_err = {0};
    struct progress progress = {0};
    bool imported = fakefs_import(tar_gz_path, dest_dir, &fs_err, progress);
    if (!imported) {
        cmux_write_error(err_out, err_len,
                         "fakefs_import failed: type=%d code=%d line=%d %s",
                         (int) fs_err.type, fs_err.code, fs_err.line,
                         fs_err.message != NULL ? fs_err.message : "");
        free(fs_err.message);
    }
    pthread_mutex_unlock(&cmux_boot_lock);
    return imported;
}

// ---- boot -------------------------------------------------------------

int cmux_ish_boot(const char *fakefs_data_path, const char *init_command) {
    if (fakefs_data_path == NULL || fakefs_data_path[0] == '\0' ||
        !cmux_path_fits_ish(fakefs_data_path))
        return _EINVAL;
    if (init_command != NULL &&
        (init_command[0] == '\0' || !cmux_path_fits_ish(init_command)))
        return _EINVAL;

    pthread_mutex_lock(&cmux_boot_lock);
    pthread_mutex_lock(&cmux_lock);
    if (cmux_boot_state == CMUX_BOOTED) {
        pthread_mutex_unlock(&cmux_lock);
        pthread_mutex_unlock(&cmux_boot_lock);
        return _EEXIST;
    }
    if (cmux_boot_state == CMUX_BOOT_FAILED) {
        int err = cmux_boot_error;
        pthread_mutex_unlock(&cmux_lock);
        pthread_mutex_unlock(&cmux_boot_lock);
        return err;
    }
    if (cmux_boot_state == CMUX_BOOTING) {
        pthread_mutex_unlock(&cmux_lock);
        pthread_mutex_unlock(&cmux_boot_lock);
        return _EBUSY;
    }
    cmux_boot_state = CMUX_BOOTING;
    pthread_mutex_unlock(&cmux_lock);

    int err = 0;
    bool root_mounted = false;
    bool proc_mounted = false;
    bool devpts_mounted = false;
    struct task *init_task = NULL;

    // The embedding thread is a host thread, not an iSH task. In particular,
    // do not let a previous failed setup leave a dangling TLS `current` here.
    current = NULL;

    // mount_root calls do_mount, whose contract requires mounts_lock.
    lock(&mounts_lock);
    err = mount_root(&fakefs, fakefs_data_path);
    unlock(&mounts_lock);
    if (err < 0)
        goto fail;
    root_mounted = true;

    // Establish a valid current before generic_* calls, matching iSH's
    // AppDelegate boot order.
    err = become_first_process();
    if (err < 0)
        goto fail;
    init_task = current;

    create_some_device_nodes();
    // Permissions on / in shipped rootfs archives are often wrong; iSH fixes
    // them the same way on boot. Failure is non-fatal for read-only archives.
    (void) generic_setattrat(AT_PWD, "/",
                             (struct attr) {.type = attr_mode, .mode = 0755}, false);

    lock(&mounts_lock);
    err = do_mount(&procfs, "proc", "/proc", "", 0);
    unlock(&mounts_lock);
    if (err < 0)
        goto fail;
    proc_mounted = true;

    lock(&mounts_lock);
    err = do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    unlock(&mounts_lock);
    if (err < 0)
        goto fail;
    devpts_mounted = true;

    tty_drivers[TTY_CONSOLE_MAJOR] = &cmux_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0)
        goto fail;

    const char *candidates[3];
    int candidate_count = 0;
    if (init_command != NULL) {
        candidates[candidate_count++] = init_command;
    } else {
        candidates[candidate_count++] = "/sbin/init";
        candidates[candidate_count++] = "/bin/sh";
    }

    err = _ENOENT;
    for (int i = 0; i < candidate_count; i++) {
        char *argv_blob = NULL;
        size_t argc = 0;
        const char *argv[] = {candidates[i], NULL};
        err = cmux_pack_args(argv, &argv_blob, &argc);
        if (err < 0)
            goto fail;
        char *envp_blob = NULL;
        size_t envc = 0;
        err = cmux_pack_env(NULL, &envp_blob, &envc);
        if (err >= 0)
            err = do_execve(candidates[i], argc, argv_blob, envp_blob);
        free(envp_blob);
        free(argv_blob);
        if (err < 0) {
            // Some direct error returns in iSH's elf loader leave the new
            // mm write lock held. Unlock before trying the next candidate,
            // otherwise the fallback exec can deadlock on its own lock.
            cmux_unlock_unstarted_exec_mm(current);
        } else {
            break;
        }
    }
    if (err < 0)
        goto fail;

    // Install before starting init so a very short-lived init still has a
    // defined lifecycle callback. The hook remains installed for all later
    // session children and chains any hook that was present at boot.
    cmux_install_exit_hook();
    // A host-created init thread can fail to allocate a pthread. Use the
    // checked entry point so this error returns through the normal mount/task
    // rollback path instead of aborting the containing iOS process.
    err = task_start_checked(init_task);
    if (err < 0)
        goto fail;
    // The host thread is not an iSH task. Leaving `current` set here would
    // make a later Swift callback on the same thread accidentally use a stale
    // task after it exits.
    current = NULL;

    pthread_mutex_lock(&cmux_lock);
    if (cmux_boot_state == CMUX_BOOTING) {
        cmux_boot_state = CMUX_BOOTED;
        cmux_boot_error = 0;
    } else if (cmux_boot_state == CMUX_BOOT_FAILED) {
        // A short-lived init may have exited between task_start and this
        // publication. Preserve the exit-hook failure instead of allowing a
        // later session open to call become_new_init_child without pid 1.
        err = cmux_boot_error;
    }
    pthread_mutex_unlock(&cmux_lock);
    pthread_mutex_unlock(&cmux_boot_lock);
    return err < 0 ? err : 0;

fail:
    // `current` is only non-null after become_first_process. Save and discard
    // the unstarted task before removing mounts so its root fd releases the
    // root mount reference.
    if (init_task == NULL && current != NULL)
        init_task = current;
    cmux_unlock_unstarted_exec_mm(init_task);
    current = NULL;
    cmux_discard_unstarted_task(init_task);
    if (devpts_mounted)
        cmux_remove_mount("/dev/pts");
    if (proc_mounted)
        cmux_remove_mount("/proc");
    if (root_mounted)
        cmux_remove_mount("");

    pthread_mutex_lock(&cmux_lock);
    cmux_boot_state = CMUX_BOOT_FAILED;
    cmux_boot_error = err < 0 ? err : _EIO;
    pthread_mutex_unlock(&cmux_lock);
    pthread_mutex_unlock(&cmux_boot_lock);
    return cmux_boot_error;
}

// ---- sessions ---------------------------------------------------------

int cmux_ish_session_open(const char *const *argv, const char *const *envp,
                          int cols, int rows,
                          cmux_ish_output_cb cb, void *context,
                          cmux_ish_input_ready_cb input_ready_cb,
                          void *input_ready_context) {
    if (cb == NULL)
        return _EINVAL;
    if (cols <= 0 || rows <= 0 || cols > UINT16_MAX || rows > UINT16_MAX)
        return _EINVAL;

    char *argv_blob = NULL;
    size_t argc = 0;
    int err = cmux_pack_args(argv, &argv_blob, &argc);
    if (err < 0)
        return err;
    char *envp_blob = NULL;
    size_t envc = 0;
    err = cmux_pack_env(envp, &envp_blob, &envc);
    if (err < 0) {
        free(argv_blob);
        return err;
    }

    struct cmux_session *session = NULL;
    int slot = -1;
    uint32_t generation = 0;
    struct cmux_session_binding *binding = NULL;

    pthread_mutex_lock(&cmux_lock);
    if (cmux_boot_state != CMUX_BOOTED) {
        err = cmux_boot_state == CMUX_BOOT_FAILED ? cmux_boot_error : _EAGAIN;
        pthread_mutex_unlock(&cmux_lock);
        free(envp_blob);
        free(argv_blob);
        return err;
    }
    for (int i = 0; i < CMUX_MAX_SESSIONS; i++) {
        if (atomic_load_explicit(&sessions[i].state, memory_order_acquire) == CMUX_SESSION_FREE &&
            sessions[i].generation < CMUX_HANDLE_MAX_GENERATION) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        pthread_mutex_unlock(&cmux_lock);
        free(envp_blob);
        free(argv_blob);
        return _EMFILE;
    }

    session = &sessions[slot];
    generation = cmux_next_generation(session);
    if (generation == 0) {
        // All currently free slots may have exhausted their generation space.
        // This is extraordinarily unlikely, but returning EMFILE is safer
        // than ever reusing an opaque handle.
        pthread_mutex_unlock(&cmux_lock);
        free(envp_blob);
        free(argv_blob);
        return _EMFILE;
    }
    session->generation = generation;
    session->pid = -1;
    atomic_store_explicit(&session->tty, NULL, memory_order_release);
    atomic_store_explicit(&session->binding, NULL, memory_order_release);
    binding = cmux_binding_create(session, cb, context, input_ready_cb, input_ready_context);
    if (binding == NULL) {
        pthread_mutex_unlock(&cmux_lock);
        free(envp_blob);
        free(argv_blob);
        return _ENOMEM;
    }
    atomic_store_explicit(&session->binding, binding, memory_order_release);
    atomic_store_explicit(&session->state, CMUX_SESSION_OPENING, memory_order_release);
    int handle = cmux_encode_handle(slot, generation);
    pthread_mutex_unlock(&cmux_lock);

    if (handle < 0) {
        cmux_abort_session_binding(session);
        free(envp_blob);
        free(argv_blob);
        return _EMFILE;
    }

    pthread_mutex_lock(&cmux_spawn_lock);
    // The public API is not reentrant from an output callback. Keep the host
    // thread out of iSH's TLS `current` slot while constructing the child.
    current = NULL;
    struct task *task = NULL;
    struct tty *tty = NULL;

    // become_new_init_child asserts that pid 1 exists. Return a normal errno
    // instead of allowing a shutdown race to abort the host process.
    lock(&pids_lock);
    bool init_alive = pid_get_task(1) != NULL;
    unlock(&pids_lock);
    if (!init_alive) {
        err = _ESRCH;
        goto fail;
    }

    err = become_new_init_child();
    // construct_task can leave its partially built task in TLS when opening
    // the root directory fails. Capture it before rollback so that iSH's
    // incomplete error path does not leak the pid, group, and resources.
    task = current;
    if (err < 0)
        goto fail;

    // pty_open_fake mutates the supplied driver's ttys/major fields and calls
    // cmux_tty_init synchronously. cmux_spawn_lock, held here, keeps that
    // driver mutation single-threaded.
    tty = pty_open_fake(&cmux_pty_driver);
    if (IS_ERR(tty)) {
        err = (int) PTR_ERR(tty);
        tty = NULL;
        goto fail;
    }

    // pty_open_fake has now finished pty_slave_init_inode, which uses the
    // union that also contains tty->data. Keep the association in the side
    // table and publish the tty only after that metadata write is complete.
    err = cmux_tty_binding_insert(tty, binding);
    if (err < 0)
        goto fail;
    // Install the vendor hook before publishing the tty or starting the task.
    // The binding already carries the host readiness callback, so the first
    // consumption edge after task start is delivered.
    lock(&tty->lock);
    tty->input_consumed_callback = cmux_tty_input_consumed;
    unlock(&tty->lock);
    atomic_store_explicit(&session->tty, tty, memory_order_release);

    char stdio_file[32];
    int written = snprintf(stdio_file, sizeof(stdio_file), "/dev/pts/%d", tty->num);
    if (written < 0 || (size_t) written >= sizeof(stdio_file)) {
        err = _ENAMETOOLONG;
        goto fail;
    }
    err = create_stdio(stdio_file, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0)
        goto fail;

    lock(&tty->lock);
    tty_set_winsize(tty, (struct winsize_) {.col = (word_t) cols, .row = (word_t) rows});
    unlock(&tty->lock);
    // The task's stdio fd now owns the remaining tty reference. tty_release
    // must be called with ttys_lock, unlike the original shim.
    lock(&ttys_lock);
    tty_release(tty);
    unlock(&ttys_lock);
    tty = NULL;

    err = do_execve(argv[0], argc, argv_blob, envp_blob);
    if (err < 0)
        goto fail;

    // iSH may destroy the task as soon as task_start_checked returns. Capture
    // the pid while the task is still owned by this opening thread, before the
    // child can run and exit. This follows the same lifetime rule as iSH's
    // fork.c task_start path.
    pid_t session_pid = task->pid;

    // Publish the pid and ACTIVE state under cmux_lock. cmux_exit_hook reads
    // pid under that lock, so writing it outside would be a C memory-model
    // data race. Publish ACTIVE before
    // starting the thread. This closes the tiny window in which a
    // short-lived command could clean up an OPENING binding; all rollback
    // paths above still remain OPENING and are owned by this function.
    pthread_mutex_lock(&cmux_lock);
    session->pid = (int) session_pid;
    atomic_store_explicit(&session->state, CMUX_SESSION_ACTIVE, memory_order_release);
    pthread_mutex_unlock(&cmux_lock);
    err = task_start_checked(task);
    if (err < 0) {
        // The task has not started, so rollback must use the OPENING path and
        // must not emit a terminal event for a handle that will be reported as
        // an open failure. The fdtable cleanup below then retires the tty.
        pthread_mutex_lock(&cmux_lock);
        if (atomic_load_explicit(&session->state, memory_order_acquire) ==
                CMUX_SESSION_ACTIVE) {
            atomic_store_explicit(&session->state, CMUX_SESSION_OPENING,
                                  memory_order_release);
        }
        pthread_mutex_unlock(&cmux_lock);
        goto fail;
    }
    current = NULL;
    pthread_mutex_unlock(&cmux_spawn_lock);

    free(envp_blob);
    free(argv_blob);
    return handle;

fail:
    cmux_unlock_unstarted_exec_mm(task);
    current = NULL;
    if (tty != NULL) {
        // No task fd owns this first reference yet. Release it correctly so
        // cmux_tty_cleanup can detach and destroy the per-open binding.
        lock(&ttys_lock);
        tty_release(tty);
        unlock(&ttys_lock);
        tty = NULL;
    }
    cmux_discard_unstarted_task(task);

    cmux_abort_session_binding(session);
    pthread_mutex_unlock(&cmux_spawn_lock);
    free(envp_blob);
    free(argv_blob);
    return err;
}

long cmux_ish_session_input(int handle, const char *bytes, size_t length) {
    if (length == 0)
        return 0;
    if (bytes == NULL)
        return _EINVAL;

    struct tty *tty = cmux_retain_tty(handle, false, NULL);
    if (tty == NULL)
        return _EBADF;
    // Matches -[Terminal sendInput:]: non-blocking write into the line
    // discipline; echo may re-enter cmux_tty_write on this thread.
    ssize_t accepted = tty_input(tty, bytes, length, false);
    cmux_release_tty(tty);
    return (long) accepted;
}

void cmux_ish_session_resize(int handle, int cols, int rows) {
    if (cols <= 0)
        cols = 1;
    if (rows <= 0)
        rows = 1;
    if (cols > UINT16_MAX)
        cols = UINT16_MAX;
    if (rows > UINT16_MAX)
        rows = UINT16_MAX;

    struct tty *tty = cmux_retain_tty(handle, false, NULL);
    if (tty == NULL)
        return;
    pid_t_ foreground_group;
    lock(&tty->lock);
    // iSH's tty_set_winsize sends SIGWINCH while holding tty->lock. That
    // signal path takes pids_lock, while the reaper can hold pids_lock and
    // wait for this tty lock in task_leave_session. Update the dimensions
    // here, capture the group, and deliver the signal after unlocking to keep
    // the lock order acyclic.
    tty->winsize = (struct winsize_) {
        .col = (word_t) cols,
        .row = (word_t) rows,
    };
    foreground_group = tty->fg_group;
    unlock(&tty->lock);
    if (foreground_group != 0)
        (void) send_group_signal(foreground_group, SIGWINCH_, SIGINFO_NIL);
    cmux_release_tty(tty);
}

void cmux_ish_session_hangup(int handle) {
    struct cmux_session *session = NULL;
    struct tty *tty = NULL;
    uint32_t generation = 0;

    // Mark the session closing before taking ttys_lock. Do not hold
    // cmux_lock while waiting for tty->lock below. That lock order can form a
    // cycle with an iSH writer (tty->lock -> binding rwlock) and exit_hook
    // (binding rwlock -> cmux_lock).
    pthread_mutex_lock(&cmux_lock);
    session = cmux_session_lookup_locked(handle, NULL);
    if (session != NULL) {
        int state = atomic_load_explicit(&session->state, memory_order_acquire);
        if (state == CMUX_SESSION_ACTIVE)
            atomic_store_explicit(&session->state, CMUX_SESSION_CLOSING, memory_order_release);
        else if (state != CMUX_SESSION_CLOSING)
            session = NULL;
    }
    if (session != NULL) {
        generation = session->generation;
    }
    pthread_mutex_unlock(&cmux_lock);

    if (session != NULL) {
        // Re-read the tty only after taking ttys_lock. Reading it before this
        // lock would leave a use-after-free window: natural cleanup can clear
        // the session pointer and free the tty between the two locks.
        lock(&ttys_lock);
        pthread_mutex_lock(&cmux_lock);
        struct tty *candidate = NULL;
        if (session->generation == generation &&
            atomic_load_explicit(&session->state, memory_order_acquire) ==
                CMUX_SESSION_CLOSING) {
            candidate = atomic_load_explicit(&session->tty, memory_order_acquire);
        }
        pthread_mutex_unlock(&cmux_lock);

        if (candidate != NULL) {
            // ttys_lock now prevents the final tty_release from freeing this
            // object while we pin it. The later side-table phase revalidates
            // generation and ownership before retiring the binding.
            lock(&candidate->lock);
            bool can_use = candidate->refcount != 0;
            if (can_use)
                candidate->refcount++;
            unlock(&candidate->lock);
            if (can_use)
                tty = candidate;
        }
        unlock(&ttys_lock);
    }

    if (session == NULL)
        return;

    // Retire the side-table entry while holding its write lock. The previous
    // implementation captured a raw binding pointer, released all locks,
    // then called finish; natural tty cleanup could free that binding first.
    // Re-validating the generation also prevents a delayed hangup from
    // affecting a new session that reused this slot.
    struct cmux_session_binding *binding = NULL;
    bool still_owned = false;
    pthread_rwlock_wrlock(&cmux_binding_rwlock);
    pthread_mutex_lock(&cmux_lock);
    if (session->generation == generation &&
        atomic_load_explicit(&session->state, memory_order_acquire) == CMUX_SESSION_CLOSING) {
        binding = atomic_load_explicit(&session->binding, memory_order_acquire);
        // Detach by binding rather than by the pinned tty. A tty pointer can
        // be absent when cleanup already dropped the session's reference, but
        // the side-table entry still has the binding identity.
        struct cmux_tty_binding_entry *entry =
            cmux_tty_binding_detach_session_locked(session, binding);
        if (entry != NULL) {
            binding = entry->binding;
            struct tty *entry_tty = entry->tty;
            free(entry);
            struct cmux_session_binding *expected_binding = binding;
            still_owned = atomic_compare_exchange_strong_explicit(
                &session->binding, &expected_binding, NULL,
                memory_order_acq_rel, memory_order_acquire);
            if (still_owned) {
                struct tty *expected_tty = entry_tty;
                atomic_compare_exchange_strong_explicit(
                    &session->tty, &expected_tty, NULL,
                    memory_order_acq_rel, memory_order_acquire);
            }
        } else {
            // Cleanup may have removed and destroyed the binding already.
            // Do not dereference session->binding unless the side-table still
            // owns it. The state can be retired only when no binding remains.
            binding = NULL;
        }
    } else {
        // The handle was retired and its slot was reused while this call was
        // waiting. Do not touch the new session.
        binding = NULL;
    }
    pthread_mutex_unlock(&cmux_lock);

    // Explicit shutdown follows the same one-shot terminal-event path as a
    // natural process exit. The event is delivered before this function
    // returns, so the host can finish its stream without polling pid state.
    if (binding != NULL)
        cmux_binding_destroy(binding, true);

    pthread_mutex_lock(&cmux_lock);
    if (session->generation == generation &&
        atomic_load_explicit(&session->state, memory_order_acquire) ==
            CMUX_SESSION_CLOSING &&
        atomic_load_explicit(&session->binding, memory_order_acquire) == NULL) {
        atomic_store_explicit(&session->state, CMUX_SESSION_FREE, memory_order_release);
    }
    pthread_mutex_unlock(&cmux_lock);
    pthread_rwlock_unlock(&cmux_binding_rwlock);

    if (tty != NULL) {
        // If natural cleanup detached the binding first, the process and its
        // foreground group are already retiring. Do not signal a stale PGID
        // that could have been reused by a later session.
        if (still_owned)
            cmux_hangup_tty(tty);
        cmux_release_tty(tty);
    }
}

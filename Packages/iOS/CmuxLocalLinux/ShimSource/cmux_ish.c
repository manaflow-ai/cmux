// cmux shim over the vendored iSH kernel. Modeled on iSH's own
// app/AppDelegate.m boot path and app/TerminalViewController.m startSession /
// app/Terminal.m pty glue, with the WKWebView terminal replaced by a raw
// byte callback (the bytes feed libghostty via GhosttySurfaceView).
#include "cmux_ish.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "fs/devices.h"
#include "fs/path.h"
#include "fs/tty.h"
#include "tools/fakefs.h"

// ---- output sinks -----------------------------------------------------

struct cmux_session {
    bool used;
    struct tty *tty;
    cmux_ish_output_cb cb;
    void *context;
    int pid;
};

#define CMUX_MAX_SESSIONS 64
static struct cmux_session sessions[CMUX_MAX_SESSIONS];
static pthread_mutex_t cmux_lock = PTHREAD_MUTEX_INITIALIZER;
// Session being wired during pty_open_fake -> ops->init.
static struct cmux_session *pending_session;
static bool booted;

// ---- tty driver -------------------------------------------------------

static int cmux_tty_init(struct tty *tty) {
    // Called with ttys_lock held from tty_get. pending_session is set by
    // cmux_ish_session_open under cmux_lock before pty_open_fake runs.
    tty->data = pending_session;
    if (pending_session != NULL)
        pending_session->tty = tty;
    return 0;
}

static int cmux_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) blocking;
    struct cmux_session *session = tty->data;
    if (session != NULL && session->cb != NULL)
        session->cb(session->context, buf, len);
    return (int) len;
}

static void cmux_tty_cleanup(struct tty *tty) {
    struct cmux_session *session = tty->data;
    tty->data = NULL;
    if (session != NULL)
        session->tty = NULL;
}

static struct tty_driver_ops cmux_tty_ops = {
    .init = cmux_tty_init,
    .write = cmux_tty_write,
    .cleanup = cmux_tty_cleanup,
};
// pty_open_fake overwrites ttys/limit/major with the pty-slave table; this
// declaration only carries the ops (same shape as iSH's ios_pty_driver).
static struct tty_driver cmux_pty_driver = {.ops = &cmux_tty_ops};

// Console for the init process: accept and discard writes.
static int cmux_console_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) tty; (void) buf; (void) blocking;
    return (int) len;
}
static struct tty_driver_ops cmux_console_ops = {
    .write = cmux_console_write,
};
DEFINE_TTY_DRIVER(cmux_console_driver, &cmux_console_ops, TTY_CONSOLE_MAJOR, 64);

// ---- helpers ----------------------------------------------------------

// Packs argv into iSH's do_execve blob: NUL-separated strings, then one
// extra NUL (same layout as +[Terminal convertCommand:toArgs:limitSize:]).
static size_t cmux_pack_args(const char *const *argv, char *out, size_t max, int *count_out) {
    char *p = out;
    int count = 0;
    for (const char *const *arg = argv; *arg != NULL; arg++) {
        const char *c = *arg;
        while (p < out + max - 2 && (*p++ = *c++))
            ;
        if (p[-1] != '\0')
            *p++ = '\0';
        count++;
    }
    *p = '\0';
    *count_out = count;
    return (size_t) (p - out) + 1;
}

static size_t cmux_pack_env(const char *const *envp, char *out, size_t max) {
    if (envp == NULL) {
        const char *term = "TERM=xterm-256color";
        size_t len = strlen(term) + 1;
        memcpy(out, term, len);
        out[len] = '\0';
        return len + 1;
    }
    char *p = out;
    for (const char *const *env = envp; *env != NULL; env++) {
        const char *c = *env;
        while (p < out + max - 2 && (*p++ = *c++))
            ;
        if (p[-1] != '\0')
            *p++ = '\0';
    }
    *p = '\0';
    return (size_t) (p - out) + 1;
}

// ---- public API -------------------------------------------------------

bool cmux_ish_import_rootfs(const char *tar_gz_path, const char *dest_dir,
                            char *err_out, size_t err_len) {
    struct fakefsify_error fs_err = {0};
    struct progress progress = {0};
    if (!fakefs_import(tar_gz_path, dest_dir, &fs_err, progress)) {
        snprintf(err_out, err_len, "fakefs_import failed: type=%d code=%d line=%d %s",
                 fs_err.type, fs_err.code, fs_err.line,
                 fs_err.message != NULL ? fs_err.message : "");
        free(fs_err.message);
        return false;
    }
    err_out[0] = '\0';
    return true;
}

int cmux_ish_boot(const char *fakefs_data_path, const char *init_command) {
    pthread_mutex_lock(&cmux_lock);
    if (booted) {
        pthread_mutex_unlock(&cmux_lock);
        return -17; // -EEXIST
    }

    int err = mount_root(&fakefs, fakefs_data_path);
    if (err < 0)
        goto fail;

    err = become_first_process();
    if (err < 0)
        goto fail;

    create_some_device_nodes();
    // Permissions on / in shipped rootfs archives are often wrong; iSH fixes
    // them the same way on boot.
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    tty_drivers[TTY_CONSOLE_MAJOR] = &cmux_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0)
        goto fail;

    const char *candidates[3];
    int candidate_count = 0;
    if (init_command != NULL)
        candidates[candidate_count++] = init_command;
    else {
        candidates[candidate_count++] = "/sbin/init";
        candidates[candidate_count++] = "/bin/sh";
    }
    err = -2; // -ENOENT
    for (int i = 0; i < candidate_count; i++) {
        char argv_blob[4096];
        int argc = 0;
        const char *argv[] = {candidates[i], NULL};
        cmux_pack_args(argv, argv_blob, sizeof(argv_blob), &argc);
        char envp_blob[4096];
        cmux_pack_env(NULL, envp_blob, sizeof(envp_blob));
        err = do_execve(candidates[i], argc, argv_blob, envp_blob);
        if (err >= 0)
            break;
    }
    if (err < 0)
        goto fail;
    task_start(current);

    booted = true;
    pthread_mutex_unlock(&cmux_lock);
    return 0;

fail:
    pthread_mutex_unlock(&cmux_lock);
    return err;
}

int cmux_ish_session_open(const char *const *argv, const char *const *envp,
                          int cols, int rows,
                          cmux_ish_output_cb cb, void *context) {
    pthread_mutex_lock(&cmux_lock);
    if (!booted) {
        pthread_mutex_unlock(&cmux_lock);
        return -11; // -EAGAIN
    }

    int slot = -1;
    for (int i = 0; i < CMUX_MAX_SESSIONS; i++) {
        if (!sessions[i].used) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        pthread_mutex_unlock(&cmux_lock);
        return -24; // -EMFILE
    }
    struct cmux_session *session = &sessions[slot];
    memset(session, 0, sizeof(*session));
    session->used = true;
    session->cb = cb;
    session->context = context;
    session->pid = -1;

    int err = become_new_init_child();
    if (err < 0)
        goto fail;

    pending_session = session;
    struct tty *tty = pty_open_fake(&cmux_pty_driver);
    pending_session = NULL;
    if (IS_ERR(tty)) {
        err = (int) PTR_ERR(tty);
        goto fail;
    }

    char stdio_file[32];
    snprintf(stdio_file, sizeof(stdio_file), "/dev/pts/%d", tty->num);
    err = create_stdio(stdio_file, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0) {
        tty_release(tty);
        goto fail;
    }

    lock(&tty->lock);
    tty_set_winsize(tty, (struct winsize_) {.col = cols, .row = rows});
    unlock(&tty->lock);
    tty_release(tty);

    char argv_blob[4096];
    int argc = 0;
    cmux_pack_args(argv, argv_blob, sizeof(argv_blob), &argc);
    char envp_blob[4096];
    cmux_pack_env(envp, envp_blob, sizeof(envp_blob));
    err = do_execve(argv[0], argc, argv_blob, envp_blob);
    if (err < 0)
        goto fail;
    session->pid = current->pid;
    task_start(current);

    pthread_mutex_unlock(&cmux_lock);
    return slot;

fail:
    session->used = false;
    session->cb = NULL;
    pthread_mutex_unlock(&cmux_lock);
    return err;
}

static struct cmux_session *cmux_session_get(int handle) {
    if (handle < 0 || handle >= CMUX_MAX_SESSIONS)
        return NULL;
    if (!sessions[handle].used)
        return NULL;
    return &sessions[handle];
}

long cmux_ish_session_input(int handle, const char *bytes, size_t length) {
    pthread_mutex_lock(&cmux_lock);
    struct cmux_session *session = cmux_session_get(handle);
    struct tty *tty = session != NULL ? session->tty : NULL;
    pthread_mutex_unlock(&cmux_lock);
    if (tty == NULL)
        return -9; // -EBADF
    // Matches -[Terminal sendInput:]: non-blocking write into the line
    // discipline; echo may re-enter cmux_tty_write on this thread.
    ssize_t accepted = tty_input(tty, bytes, length, 0);
    return (long) accepted;
}

void cmux_ish_session_resize(int handle, int cols, int rows) {
    pthread_mutex_lock(&cmux_lock);
    struct cmux_session *session = cmux_session_get(handle);
    struct tty *tty = session != NULL ? session->tty : NULL;
    pthread_mutex_unlock(&cmux_lock);
    if (tty == NULL)
        return;
    lock(&tty->lock);
    tty_set_winsize(tty, (struct winsize_) {.col = cols, .row = rows});
    unlock(&tty->lock);
}

void cmux_ish_session_hangup(int handle) {
    pthread_mutex_lock(&cmux_lock);
    struct cmux_session *session = cmux_session_get(handle);
    struct tty *tty = NULL;
    if (session != NULL) {
        tty = session->tty;
        session->cb = NULL;
        session->context = NULL;
    }
    pthread_mutex_unlock(&cmux_lock);
    if (tty != NULL) {
        lock(&tty->lock);
        tty_hangup(tty);
        unlock(&tty->lock);
    }
    pthread_mutex_lock(&cmux_lock);
    if (session != NULL) {
        session->used = false;
        session->tty = NULL;
    }
    pthread_mutex_unlock(&cmux_lock);
}

int cmux_ish_session_pid(int handle) {
    pthread_mutex_lock(&cmux_lock);
    struct cmux_session *session = cmux_session_get(handle);
    int pid = session != NULL ? session->pid : -1;
    pthread_mutex_unlock(&cmux_lock);
    return pid;
}

// cmux shim over the vendored iSH usermode-x86 kernel (vendor/ish).
//
// This is the ONLY header the Swift side sees. It deliberately exposes no
// iSH types: sessions are opaque integer handles, output arrives on a C
// callback from kernel threads (the callback must not block and must not call
// back into this API synchronously).
#ifndef CMUX_ISH_H
#define CMUX_ISH_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Raw PTY output produced by the emulated slave side. Runs on an emulated
// task's thread (or, for input echo, the caller of cmux_ish_session_input).
// `bytes` is borrowed and is valid only for the duration of the callback.
// A callback must consume or copy it before returning, and must not block.
//
// The callback receives one terminal event when the process exits or the
// session is hung up: `bytes == NULL` and `length == 0`. This is not an output
// chunk. It is delivered after all ordinary output callbacks, and exactly
// once for every successfully opened session. A bridge that retained
// `context` must release that ownership from this terminal event. If opening
// the session fails, no terminal event is sent and the caller retains the
// usual responsibility for releasing its context.
typedef void (*cmux_ish_output_cb)(void *_Nullable context,
                                   const char *_Nullable bytes,
                                   size_t length);

// Called after the emulated process consumes bytes from the tty input buffer.
// The callback runs while the tty lock is held. It may run on an iSH task
// thread, or on the host thread that calls cmux_ish_session_input when input
// echo or a line-discipline operation consumes bytes. It must return
// immediately and must not call back into this API synchronously. Hosts use it
// only to signal a non-blocking input waiter.
typedef void (*cmux_ish_input_ready_cb)(void *_Nullable context);

// One-shot import of an Alpine rootfs tarball (.tar.gz) into a fakefs
// directory. Returns false and fills err_out (NUL-terminated) on failure.
// Must run before cmux_ish_boot; safe on any thread.
bool cmux_ish_import_rootfs(const char *_Nonnull tar_gz_path,
                            const char *_Nonnull dest_dir,
                            char *_Nonnull err_out,
                            size_t err_len);

// Boots the kernel exactly once per process: mounts the fakefs root, mounts
// /proc and /dev/pts, installs the discard console, and starts the init
// process (`init_command`, e.g. "/bin/sh"; NULL uses /sbin/init then /bin/sh).
// Returns 0 on success, a negative Linux errno on failure. Not idempotent:
// callers must serialize and call at most once (returns -EEXIST after
// a successful boot).
int cmux_ish_boot(const char *_Nonnull fakefs_data_path,
                  const char *_Nullable init_command);

// Opens a pty pair, spawns `command` (argv, NULL-terminated; envp entries
// "KEY=VALUE", NULL-terminated, may be NULL for a default TERM) attached to
// the slave, and returns an opaque session handle >= 0, or a negative Linux
// errno. The handle is not a slot index and must not be persisted across
// process launches. Output bytes stream to `cb` until the terminal event
// described above. `input_ready_cb` may be NULL; when set it is installed
// before the child starts, so no tty consumption edge is lost, and it is
// cleared by the terminal event or by hangup, whichever happens first.
int cmux_ish_session_open(const char *_Nullable const *_Nonnull argv,
                          const char *_Nullable const *_Nullable envp,
                          int cols, int rows,
                          cmux_ish_output_cb _Nonnull cb,
                          void *_Nullable context,
                          cmux_ish_input_ready_cb _Nullable input_ready_cb,
                          void *_Nullable input_ready_context);

// Writes input bytes to the session's tty (keyboard/paste). Non-blocking;
// returns bytes accepted (may be < length if the 4KB line buffer is full)
// or a negative errno.
long cmux_ish_session_input(int session, const char *_Nonnull bytes, size_t length);

// Updates the tty window size and signals SIGWINCH to the foreground group.
void cmux_ish_session_resize(int session, int cols, int rows);

// Hangs up the tty (SIGHUP to the session), sends the terminal event, and
// waits for callbacks already in flight to return. The handle is invalid
// afterwards. The terminal event owns context cleanup; callers must not
// release context a second time after this function returns. Calling this
// function more than once for the same handle is safe; callbacks must not call
// it synchronously.
void cmux_ish_session_hangup(int session);

#ifdef __cplusplus
}
#endif

#endif

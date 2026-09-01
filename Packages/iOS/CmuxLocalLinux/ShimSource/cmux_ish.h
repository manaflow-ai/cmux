// cmux shim over the vendored iSH usermode-x86 kernel (vendor/ish).
//
// This is the ONLY header the Swift side sees. It deliberately exposes no
// iSH types: sessions are integer handles, output arrives on a C callback
// from kernel threads (the callback must not block and must not call back
// into this API synchronously).
#ifndef CMUX_ISH_H
#define CMUX_ISH_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Raw PTY output produced by the emulated slave side. Runs on an emulated
// task's thread (or, for input echo, the caller of cmux_ish_session_input).
typedef void (*cmux_ish_output_cb)(void *_Nullable context,
                                   const char *_Nullable bytes,
                                   size_t length);

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
// the slave, and returns a session handle >= 0, or a negative Linux errno.
// Output bytes stream to `cb` until cmux_ish_session_hangup.
int cmux_ish_session_open(const char *_Nullable const *_Nonnull argv,
                          const char *_Nullable const *_Nullable envp,
                          int cols, int rows,
                          cmux_ish_output_cb _Nonnull cb,
                          void *_Nullable context);

// Writes input bytes to the session's tty (keyboard/paste). Non-blocking;
// returns bytes accepted (may be < length if the 4KB line buffer is full)
// or a negative errno.
long cmux_ish_session_input(int session, const char *_Nonnull bytes, size_t length);

// Updates the tty window size and signals SIGWINCH to the foreground group.
void cmux_ish_session_resize(int session, int cols, int rows);

// Hangs up the tty (SIGHUP to the session) and detaches the output callback.
// The handle is invalid afterwards.
void cmux_ish_session_hangup(int session);

// Emulated pid of the session leader, or -1.
int cmux_ish_session_pid(int session);

#ifdef __cplusplus
}
#endif

#endif

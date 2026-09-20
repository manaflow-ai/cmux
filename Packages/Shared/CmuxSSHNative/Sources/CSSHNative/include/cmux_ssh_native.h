#ifndef CMUX_SSH_NATIVE_H
#define CMUX_SSH_NATIVE_H
#include <stddef.h>
#include <stdint.h>

/* This shim never logs remote strings or credential bytes. All calls on one
 * handle are serialized by the owning Swift actor, and all SSH I/O is nonblocking. */
typedef struct cmux_ssh cmux_ssh;
enum { CMUX_SSH_OK=0, CMUX_SSH_AGAIN=1, CMUX_SSH_CHALLENGE=2,
       CMUX_SSH_DENIED=3, CMUX_SSH_PARTIAL=4, CMUX_SSH_ERROR=-1 };

cmux_ssh *cmux_ssh_create(const char *host, int port, const char *user);
void cmux_ssh_destroy(cmux_ssh *s);
int cmux_ssh_connect(cmux_ssh *s);
int cmux_ssh_wait(cmux_ssh *s, int timeout_ms);
int cmux_ssh_fd(cmux_ssh *s);
int cmux_ssh_wants_write(cmux_ssh *s);
int cmux_ssh_host_key(cmux_ssh *s, char *algorithm, size_t algorithm_size,
                      char *fingerprint, size_t fingerprint_size);
int cmux_ssh_auth_password(cmux_ssh *s, const char *password);
int cmux_ssh_load_private_key(cmux_ssh *s, const char *key, const char *passphrase);
int cmux_ssh_auth_key(cmux_ssh *s);
int cmux_ssh_auth_none(cmux_ssh *s);
int cmux_ssh_auth_keyboard(cmux_ssh *s);
int cmux_ssh_prompt_count(cmux_ssh *s);
const char *cmux_ssh_prompt(cmux_ssh *s, unsigned index, int *echo);
const char *cmux_ssh_prompt_name(cmux_ssh *s);
const char *cmux_ssh_prompt_instruction(cmux_ssh *s);
int cmux_ssh_prompt_answer(cmux_ssh *s, unsigned index, const char *answer);
int cmux_ssh_open_channel(cmux_ssh *s);
int cmux_ssh_environment(cmux_ssh *s, const char *name, const char *value);
int cmux_ssh_request_pty(cmux_ssh *s, int columns, int rows);
int cmux_ssh_request_shell(cmux_ssh *s);
int cmux_ssh_request_exec(cmux_ssh *s, const char *command);
int cmux_ssh_resize(cmux_ssh *s, int columns, int rows);
int cmux_ssh_read_timeout(cmux_ssh *s, void *buffer, uint32_t capacity, int stderr_stream, int timeout_ms);
int cmux_ssh_write(cmux_ssh *s, const void *buffer, uint32_t count);
int cmux_ssh_eof(cmux_ssh *s);
int cmux_ssh_closed(cmux_ssh *s);
int cmux_ssh_sftp_read_file(cmux_ssh *s, const char *path, void *buffer,
                            uint32_t capacity, uint32_t *written);
int cmux_ssh_sftp_list(cmux_ssh *s, const char *path, char *buffer,
                       uint32_t capacity, uint32_t *written);
#endif

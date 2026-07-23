#ifndef IROH_PHONE_MAC_DEMO_FFI_H
#define IROH_PHONE_MAC_DEMO_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

char *iroh_demo_ping(const char *ticket, const char *message);
char *iroh_demo_terminal_command(const char *ticket, const char *command);
void iroh_demo_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif

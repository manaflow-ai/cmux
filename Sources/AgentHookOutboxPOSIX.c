#include "AgentHookOutboxPOSIX.h"

#include <fcntl.h>
#include <sys/mman.h>

int cmux_agent_hook_shm_open_readonly(const char *name) {
    return shm_open(name, O_RDONLY);
}

#if DEBUG
int cmux_agent_hook_shm_create_for_testing(const char *name) {
    return shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
}
#endif

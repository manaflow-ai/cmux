#pragma once

int cmux_agent_hook_shm_open_readonly(const char *name);

#if DEBUG
int cmux_agent_hook_shm_create_for_testing(const char *name);
#endif

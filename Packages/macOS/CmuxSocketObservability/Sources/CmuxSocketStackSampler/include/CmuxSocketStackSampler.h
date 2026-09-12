#ifndef CMUX_SOCKET_STACK_SAMPLER_H
#define CMUX_SOCKET_STACK_SAMPLER_H

#include <mach/mach.h>
#include <stddef.h>
#include <stdint.h>

size_t CMUXCaptureThreadStackAddresses(thread_act_t thread, uintptr_t *addresses, size_t capacity);

#endif

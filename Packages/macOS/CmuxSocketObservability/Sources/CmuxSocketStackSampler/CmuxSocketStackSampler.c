#include "CmuxSocketStackSampler.h"
#include <mach/mach_vm.h>
#include <mach/thread_status.h>
#include <pthread.h>
#include <ptrauth.h>

static uintptr_t normalize_instruction_pointer(uintptr_t address) {
#if defined(__arm64__)
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_function_pointer);
#else
    return address;
#endif
}

static kern_return_t initial_registers(thread_act_t thread, uintptr_t *instruction_pointer, uintptr_t *frame_pointer) {
#if defined(__x86_64__)
    x86_thread_state64_t state = {0};
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    if (result == KERN_SUCCESS) {
        *instruction_pointer = state.__rip;
        *frame_pointer = state.__rbp;
    }
    return result;
#elif defined(__arm64__)
    arm_thread_state64_t state = {0};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (result == KERN_SUCCESS) {
        *instruction_pointer = arm_thread_state64_get_pc(state);
        *frame_pointer = arm_thread_state64_get_fp(state);
    }
    return result;
#else
    return KERN_NOT_SUPPORTED;
#endif
}

size_t CMUXCaptureThreadStackAddresses(thread_act_t thread, uintptr_t *addresses, size_t capacity) {
    if (capacity == 0 || addresses == NULL || thread == MACH_PORT_NULL ||
        thread == pthread_mach_thread_np(pthread_self())) {
        return 0;
    }

    size_t captured_count = 0;
    uintptr_t instruction_pointer = 0;
    uintptr_t frame_pointer = 0;
    if (initial_registers(thread, &instruction_pointer, &frame_pointer) == KERN_SUCCESS) {
        addresses[captured_count++] = normalize_instruction_pointer(instruction_pointer);
        for (size_t walked_count = 1; walked_count < capacity &&
             frame_pointer >= 4096 && frame_pointer % sizeof(uintptr_t) == 0; walked_count++) {
            struct {
                uintptr_t previous_frame_pointer;
                uintptr_t return_address;
            } record = {0};
            mach_vm_size_t bytes_read = 0;
            kern_return_t result = mach_vm_read_overwrite(
                mach_task_self(), frame_pointer, sizeof(record),
                (mach_vm_address_t)&record, &bytes_read
            );
            if (result != KERN_SUCCESS || bytes_read != sizeof(record)) {
                break;
            }
            uintptr_t return_address = normalize_instruction_pointer(record.return_address);
            if (return_address != 0) {
                addresses[captured_count++] = return_address;
            }
            if (record.previous_frame_pointer <= frame_pointer ||
                record.previous_frame_pointer - frame_pointer > 8 * 1024 * 1024) {
                break;
            }
            frame_pointer = record.previous_frame_pointer;
        }
    }

    return captured_count;
}

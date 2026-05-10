#pragma once

#include <stddef.h>

typedef struct CmxIrohHostHandle CmxIrohHostHandle;

CmxIrohHostHandle *_Nullable cmux_iroh_host_start(
    const char *_Nonnull config_json,
    char *_Nonnull ticket_out,
    size_t ticket_out_len,
    char *_Nullable error_out,
    size_t error_out_len
);

void cmux_iroh_host_stop(CmxIrohHostHandle *_Nullable handle);
void cmux_iroh_host_retire(CmxIrohHostHandle *_Nullable handle);

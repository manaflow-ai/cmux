#ifndef CMUX_NEXT_MALLOC_ZONE_H_
#define CMUX_NEXT_MALLOC_ZONE_H_
#ifdef __cplusplus
extern "C" {
#endif
// Chromium's EarlyMallocZoneRegistration (base/allocator/
// early_zone_registration_apple.cc), for a host that loads the Chromium
// framework later, from another thread. Call once, first thing in main,
// while the process has one thread. Returns 1 when installed.
int cmux_early_malloc_zone_registration(void);
#ifdef __cplusplus
}
#endif
#endif

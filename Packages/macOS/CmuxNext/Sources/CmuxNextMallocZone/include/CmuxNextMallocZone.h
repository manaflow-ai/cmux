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
// Seconds since 1970 when this image's first initializer ran (before `main`; the launch mark
// `premain.first_initializer`), 0 when it did not.
double cmux_next_first_initializer_epoch(void);
#ifdef __cplusplus
}
#endif
#endif

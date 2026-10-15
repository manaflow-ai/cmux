#ifndef CMUX_CEF_MALLOC_ZONE_H_
#define CMUX_CEF_MALLOC_ZONE_H_
#ifdef __cplusplus
extern "C" {
#endif
// Chromium's EarlyMallocZoneRegistration (base/allocator/
// early_zone_registration_apple.cc), for a host that loads the Chromium
// framework later, from another thread. Ported from cmux Next.
//
// The Chromium framework uses PartitionAlloc as malloc. Its constructor (run
// at dlopen) swaps the default malloc zone; between two of its calls no zone
// owns system allocations, and a free() on another thread then CHECK-fails
// ("No zone found"). A delegating default zone installed while the process
// has one thread removes that window.
//
// The image constructor installs it before main, only when the app bundle
// embeds the Chromium framework (or CMUX_CEF_RUNTIME names one): a build
// without CEF keeps the system zones exactly as they are.
// Returns 1 when installed, 0 otherwise.
int cmux_early_malloc_zone_registration(void);
// 1 when the constructor installed the delegating zone in this process.
int cmux_cef_early_malloc_zone_installed(void);
#ifdef __cplusplus
}
#endif
#endif

#include "CmuxNextMallocZone.h"

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <string.h>

// Must match partition_alloc's kDelegatingZoneName: PartitionAlloc's zone
// constructor replaces a default zone with this name without ever leaving
// the process with no zone that owns system allocations.
static const char kDelegatingZoneName[] = "DelegatingDefaultZoneForPartitionAlloc";
static const char kPartitionAllocZoneName[] = "PartitionAlloc";

static malloc_zone_t g_delegating_zone;
static malloc_introspection_t g_delegating_introspect;
static malloc_zone_t* g_default_zone;

static void* d_malloc(malloc_zone_t* z, size_t size) { return g_default_zone->malloc(g_default_zone, size); }
static void* d_calloc(malloc_zone_t* z, size_t n, size_t size) { return g_default_zone->calloc(g_default_zone, n, size); }
static void* d_valloc(malloc_zone_t* z, size_t size) { return g_default_zone->valloc(g_default_zone, size); }
static void* d_realloc(malloc_zone_t* z, void* p, size_t size) { return g_default_zone->realloc(g_default_zone, p, size); }
static unsigned d_batch_malloc(malloc_zone_t* z, size_t size, void** results, unsigned n) {
  return g_default_zone->batch_malloc(g_default_zone, size, results, n);
}
static void* d_memalign(malloc_zone_t* z, size_t alignment, size_t size) {
  return g_default_zone->memalign(g_default_zone, alignment, size);
}
// Never claims memory, so free() always skips this zone.
static size_t d_size(malloc_zone_t* z, const void* p) { return 0; }
// CoreFoundation calls malloc_zone_free(zone, ptr) directly: forward.
static void d_free(malloc_zone_t* z, void* p) { g_default_zone->free(g_default_zone, p); }
static void d_free_definite_size(malloc_zone_t* z, void* p, size_t size) {
  g_default_zone->free_definite_size(g_default_zone, p, size);
}
static void d_batch_free(malloc_zone_t* z, void** p, unsigned n) { g_default_zone->batch_free(g_default_zone, p, n); }
static void d_try_free_default(malloc_zone_t* z, void* p) { g_default_zone->try_free_default(g_default_zone, p); }
static size_t d_pressure_relief(malloc_zone_t* z, size_t goal) { return 0; }

static kern_return_t i_enumerator(task_t task, void* context, unsigned type_mask, vm_address_t zone_address,
                                  memory_reader_t reader, vm_range_recorder_t recorder) {
  return KERN_SUCCESS;
}
static size_t i_good_size(malloc_zone_t* z, size_t size) {
  return g_default_zone->introspect->good_size(g_default_zone, size);
}
static boolean_t i_check(malloc_zone_t* z) { return 1; }
static void i_print(malloc_zone_t* z, boolean_t verbose) {}
static void i_log(malloc_zone_t* z, void* address) {}
static void i_lock(malloc_zone_t* z) {}
static void i_statistics(malloc_zone_t* z, malloc_statistics_t* stats) { memset(stats, 0, sizeof *stats); }
static boolean_t i_zone_locked(malloc_zone_t* z) { return 0; }
static boolean_t i_enable_discharge(malloc_zone_t* z) { return 0; }
static void i_disable_discharge(malloc_zone_t* z) {}
static void i_discharge(malloc_zone_t* z, void* memory) {}

static int zone_registered(const char* name) {
  vm_address_t* zones = NULL;
  unsigned count = 0;
  if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) != KERN_SUCCESS) return 0;
  for (unsigned i = 0; i < count; i++) {
    malloc_zone_t* zone = (malloc_zone_t*)zones[i];
    if (zone->zone_name && strcmp(zone->zone_name, name) == 0) return 1;
  }
  return 0;
}

static malloc_zone_t* default_zone(void) {
  vm_address_t* zones = NULL;
  unsigned count = 0;
  if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) != KERN_SUCCESS || count == 0) return NULL;
  return (malloc_zone_t*)zones[0];
}

int cmux_early_malloc_zone_registration(void) {
  if (zone_registered(kDelegatingZoneName) || zone_registered(kPartitionAllocZoneName)) return 0;
  malloc_zone_t* purgeable = malloc_default_purgeable_zone();
  g_default_zone = default_zone();
  if (!g_default_zone) return 0;

  g_delegating_zone.malloc = d_malloc;
  g_delegating_zone.calloc = d_calloc;
  g_delegating_zone.valloc = d_valloc;
  g_delegating_zone.realloc = d_realloc;
  g_delegating_zone.batch_malloc = d_batch_malloc;
  g_delegating_zone.memalign = d_memalign;
  g_delegating_zone.size = d_size;
  g_delegating_zone.free = d_free;
  g_delegating_zone.free_definite_size = d_free_definite_size;
  g_delegating_zone.batch_free = d_batch_free;
  if (g_default_zone->version >= 13 && g_default_zone->try_free_default) {
    g_delegating_zone.try_free_default = d_try_free_default;
  }
  g_delegating_zone.pressure_relief = d_pressure_relief;

  g_delegating_introspect.enumerator = i_enumerator;
  g_delegating_introspect.good_size = i_good_size;
  g_delegating_introspect.check = i_check;
  g_delegating_introspect.print = i_print;
  g_delegating_introspect.log = i_log;
  g_delegating_introspect.force_lock = i_lock;
  g_delegating_introspect.force_unlock = i_lock;
  g_delegating_introspect.reinit_lock = i_lock;
  g_delegating_introspect.statistics = i_statistics;
  g_delegating_introspect.zone_locked = i_zone_locked;
  g_delegating_introspect.enable_discharge_checking = i_enable_discharge;
  g_delegating_introspect.disable_discharge_checking = i_disable_discharge;
  g_delegating_introspect.discharge = i_discharge;

  g_delegating_zone.version = 13;
  g_delegating_zone.introspect = &g_delegating_introspect;
  g_delegating_zone.zone_name = kDelegatingZoneName;

  // |default|...|delegating| -> |delegating|...| -> |delegating|...|default|
  malloc_zone_register(&g_delegating_zone);
  malloc_zone_unregister(g_default_zone);
  malloc_zone_register(g_default_zone);
  // Keep the purgeable zone after the default one.
  malloc_zone_unregister(purgeable);
  malloc_zone_register(purgeable);
  return default_zone() == &g_delegating_zone;
}

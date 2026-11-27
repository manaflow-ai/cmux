//! Return already-free system allocator pages after a large eviction run.
//! Decision 117: only the owned retirement worker calls this, never a writer turn.

pub(crate) fn release_free_pages() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        unsafe extern "C" {
            fn malloc_trim(pad: usize) -> std::ffi::c_int;
        }
        // SAFETY: no caller-owned pointer is passed. glibc documents
        // malloc_trim as MT-Safe; zero asks it to return all free whole pages.
        let _ = unsafe { malloc_trim(0) };
    }
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
        }
        // SAFETY: the thread-safe allocator API accepts NULL for all zones
        // and zero for an unrestricted goal. No caller-owned pointer is passed.
        let _ = unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
    }
}

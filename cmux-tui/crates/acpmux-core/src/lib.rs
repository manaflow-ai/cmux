//! The v2 agent service core.
//!
//! The core is split into small modules with explicit ownership boundaries:
//!
//! * [`wire`] owns the bounded frame and generic `sub`/`page` request shapes.
//! * [`hub`] owns the published summary index and its one writer.
//!
//! Chat actors, peer links and lifecycle code build on these modules in later
//! PRs. This crate deliberately has no whole-list reply type.

pub mod boot;
pub mod chat;
pub mod conn;
#[cfg(all(test, feature = "allocation-metrics"))]
mod allocation_metrics {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::sync::atomic::{AtomicIsize, Ordering};

    static LIVE_BYTES: AtomicIsize = AtomicIsize::new(0);

    struct CountingAllocator;

    fn bounded_delta(new_size: usize, old_size: usize) -> isize {
        let limit = isize::MAX as usize;
        if new_size >= old_size {
            new_size.saturating_sub(old_size).min(limit) as isize
        } else {
            -(old_size.saturating_sub(new_size).min(limit) as isize)
        }
    }

    fn adjust(delta: isize) {
        let _ = LIVE_BYTES.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |live| {
            Some(live.saturating_add(delta))
        });
    }

    // SAFETY: every operation forwards to System and only updates an atomic counter.
    unsafe impl GlobalAlloc for CountingAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let ptr = unsafe { System.alloc(layout) };
            if !ptr.is_null() {
                adjust(bounded_delta(layout.size(), 0));
            }
            ptr
        }

        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            let ptr = unsafe { System.alloc_zeroed(layout) };
            if !ptr.is_null() {
                adjust(bounded_delta(layout.size(), 0));
            }
            ptr
        }

        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            adjust(bounded_delta(0, layout.size()));
            unsafe { System.dealloc(ptr, layout) }
        }

        unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            let next = unsafe { System.realloc(ptr, layout, new_size) };
            if !next.is_null() {
                adjust(bounded_delta(new_size, layout.size()));
            }
            next
        }
    }

    #[global_allocator]
    static ALLOCATOR: CountingAllocator = CountingAllocator;

    pub(crate) fn live_bytes() -> u64 {
        LIVE_BYTES.load(Ordering::Relaxed).max(0) as u64
    }
}

mod memory;

pub mod hub;
pub mod life;
pub mod registry;
pub mod wire;

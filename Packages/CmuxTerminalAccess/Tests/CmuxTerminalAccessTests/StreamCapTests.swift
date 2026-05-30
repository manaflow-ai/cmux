import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct StreamCapTests {
    private let s1: SurfaceHandle = .ref(kind: "surface", ordinal: 1)
    private let s2: SurfaceHandle = .ref(kind: "surface", ordinal: 2)

    @Test func acquireUntilCap() {
        let cap = StreamCap(maxPerSurface: 3)
        let t1 = cap.acquire(surface: s1)
        let t2 = cap.acquire(surface: s1)
        let t3 = cap.acquire(surface: s1)
        let t4 = cap.acquire(surface: s1)
        #expect(t1 != nil)
        #expect(t2 != nil)
        #expect(t3 != nil)
        #expect(t4 == nil, "fourth acquire on cap=3 must return nil")
        #expect(cap.openCount(for: s1) == 3)
    }

    @Test func releaseFreesSlot() {
        let cap = StreamCap(maxPerSurface: 2)
        let t1 = cap.acquire(surface: s1)
        let t2 = cap.acquire(surface: s1)
        #expect(t1 != nil)
        #expect(t2 != nil)
        #expect(cap.acquire(surface: s1) == nil)
        t1?.release()
        #expect(cap.openCount(for: s1) == 1)
        let t3 = cap.acquire(surface: s1)
        #expect(t3 != nil)
        _ = t2  // keep reference so deinit doesn't auto-release before assertion
        _ = t3
    }

    @Test func surfacesAreIndependent() {
        let cap = StreamCap(maxPerSurface: 1)
        let a = cap.acquire(surface: s1)
        let b = cap.acquire(surface: s2)
        #expect(a != nil)
        #expect(b != nil)
        #expect(cap.acquire(surface: s1) == nil)
        #expect(cap.acquire(surface: s2) == nil)
        _ = a; _ = b
    }

    @Test func releaseIsIdempotent() {
        let cap = StreamCap(maxPerSurface: 1)
        let t = cap.acquire(surface: s1)!
        t.release()
        t.release()  // second release must not double-decrement
        t.release()
        #expect(cap.openCount(for: s1) == 0)
    }

    @Test func deinitReleasesSlot() {
        let cap = StreamCap(maxPerSurface: 1)
        do {
            let _ = cap.acquire(surface: s1)!  // scope-local — released by deinit
        }
        #expect(cap.openCount(for: s1) == 0)
    }
}

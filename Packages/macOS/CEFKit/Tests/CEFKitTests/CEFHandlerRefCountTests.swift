import CCEF
import Foundation
import Testing

@testable import CEFKit

/// A plain owner object so tests can observe deallocation through a weak
/// reference.
private final class HandlerOwner {}

/// The handler refcount trampolines are pure Swift (CEF sees only C function
/// pointers), so the exact ownership contract CEF relies on is testable
/// without loading libcef: nothing here touches CEFRuntime's dlsym statics.
@Suite("CEFHandler reference counting")
struct CEFHandlerRefCountTests {
    @Test func allocationRetainsOwnerUntilLastRelease() {
        weak var weakOwner: HandlerOwner?
        var raw: UnsafeMutableRawPointer!
        do {
            let owner = HandlerOwner()
            weakOwner = owner
            raw = UnsafeMutableRawPointer(CEFHandler.allocate(cef_load_handler_t.self, object: owner))
        }
        #expect(weakOwner != nil, "the struct's allocation reference must retain the owner")
        cefRelease(raw)
        #expect(weakOwner == nil, "dropping the last reference must release the owner")
    }

    @Test func baseCallbacksTrackReferenceCount() {
        let owner = HandlerOwner()
        let ptr = CEFHandler.allocate(cef_load_handler_t.self, object: owner)
        let base = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: cef_base_ref_counted_t.self)
        #expect(base.pointee.has_one_ref?(base) == 1)
        #expect(base.pointee.has_at_least_one_ref?(base) == 1)
        base.pointee.add_ref?(base)
        #expect(base.pointee.has_one_ref?(base) == 0)
        #expect(base.pointee.has_at_least_one_ref?(base) == 1)
        #expect(base.pointee.release?(base) == 0, "release above zero must not destroy")
        #expect(base.pointee.has_one_ref?(base) == 1)
        #expect(base.pointee.release?(base) == 1, "the final release must destroy")
    }

    @Test func retainBalancesTheGetterConvention() {
        weak var weakOwner: HandlerOwner?
        var raw: UnsafeMutableRawPointer!
        do {
            let owner = HandlerOwner()
            weakOwner = owner
            raw = UnsafeMutableRawPointer(CEFHandler.allocate(cef_load_handler_t.self, object: owner))
        }
        CEFHandler.retain(raw)
        cefRelease(raw)
        #expect(weakOwner != nil, "the allocation reference must survive a balanced retain/release pair")
        cefRelease(raw)
        #expect(weakOwner == nil)
    }

    @Test func objectRecoversTheOwningInstance() {
        let owner = HandlerOwner()
        let ptr = CEFHandler.allocate(cef_load_handler_t.self, object: owner)
        let raw = UnsafeMutableRawPointer(ptr)
        #expect(CEFHandler.object(HandlerOwner.self, from: raw) === owner)
        cefRelease(raw)
    }
}

@Suite("CEFClientImpl ownership")
struct CEFClientImplOwnershipTests {
    @Test func lifeSpanHandlerRoutesPopupTargetBeforeRejectingUnownedBrowser() {
        let impl = CEFClientImpl()
        var routedURL: String?
        impl.onPopupRequestedForTesting = { routedURL = $0 }
        let clientPtr = impl.makeClientStruct()
        let lifeSpan = clientPtr.pointee.get_life_span_handler?(clientPtr)
        let disposition = cef_window_open_disposition_t(rawValue: CEF_WOD_UNKNOWN.rawValue)
        let cancelled = withCEFString("https://example.com/popup") { targetURL in
            lifeSpan?.pointee.on_before_popup?(
                lifeSpan, nil, nil, 0, targetURL, nil, disposition, 0,
                nil, nil, nil, nil, nil, nil
            )
        }
        #expect(cancelled == 1)
        #expect(routedURL == "https://example.com/popup")
        cefRelease(UnsafeMutableRawPointer(lifeSpan!))
        impl.releaseCachedSubHandlers()
        cefRelease(UnsafeMutableRawPointer(clientPtr))
    }

    /// The get_*_handler callbacks must return one cached struct per handler
    /// kind with a fresh reference per call (CEF releases what getters hand
    /// out), leaving exactly the allocation reference cached on the impl.
    @Test func gettersCacheOneHandlerAndAddRefPerCall() {
        let impl = CEFClientImpl()
        let clientPtr = impl.makeClientStruct()
        let first = clientPtr.pointee.get_life_span_handler?(clientPtr)
        let second = clientPtr.pointee.get_life_span_handler?(clientPtr)
        #expect(first != nil && first == second, "repeat getter calls must return the cached struct")
        let base = UnsafeMutableRawPointer(first!).assumingMemoryBound(to: cef_base_ref_counted_t.self)
        #expect(base.pointee.has_one_ref?(base) == 0, "each getter call must add a reference")
        cefRelease(UnsafeMutableRawPointer(first!))
        cefRelease(UnsafeMutableRawPointer(second!))
        #expect(
            base.pointee.has_one_ref?(base) == 1,
            "after CEF returns the getter references only the cached allocation reference remains"
        )
        impl.releaseCachedSubHandlers()
        cefRelease(UnsafeMutableRawPointer(clientPtr))
    }

    /// Regression for the close-handshake leak: the cached allocation
    /// reference on each sub-handler retains the impl, so after CEF releases
    /// everything it was handed (getter references plus the client's
    /// creation reference), the impl must be freed by
    /// releaseCachedSubHandlers — exactly what on_before_close runs.
    @Test func closeHandshakeReleasesTheClientImpl() {
        weak var weakImpl: CEFClientImpl?
        do {
            let impl = CEFClientImpl()
            weakImpl = impl
            let clientPtr = impl.makeClientStruct()
            let lifeSpan = clientPtr.pointee.get_life_span_handler?(clientPtr)
            let load = clientPtr.pointee.get_load_handler?(clientPtr)
            let display = clientPtr.pointee.get_display_handler?(clientPtr)
            #expect(lifeSpan != nil && load != nil && display != nil)
            // CEF releases the references the getters handed out ...
            cefRelease(UnsafeMutableRawPointer(lifeSpan!))
            cefRelease(UnsafeMutableRawPointer(load!))
            cefRelease(UnsafeMutableRawPointer(display!))
            // ... and the client's creation reference transferred at
            // cef_browser_host_create_browser time.
            cefRelease(UnsafeMutableRawPointer(clientPtr))
            // on_before_close drops the cached allocation references.
            impl.releaseCachedSubHandlers()
        }
        #expect(weakImpl == nil, "the close handshake must free the client impl and its handler structs")
    }
}

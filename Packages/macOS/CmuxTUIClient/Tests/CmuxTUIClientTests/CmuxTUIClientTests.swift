import Testing
@testable import CmuxTUIClient

struct CmuxTUIClientTests {
    @Test("Native render descriptor matches the Rust C ABI")
    func renderDescriptorLayout() {
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.size == 16)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.stride == 16)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.alignment == 8)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.kind) == 0)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.columns) == 4)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.rows) == 6)
        #expect(MemoryLayout<CmuxTUIRenderEventDescriptor>.offset(of: \.payloadLength) == 8)
    }

    @Test("Render event values remain wire compatible")
    func renderEventKinds() {
        #expect(CmuxTUIRenderEvent.Kind.reset.rawValue == 1)
        #expect(CmuxTUIRenderEvent.Kind.bytes.rawValue == 2)
        #expect(CmuxTUIRenderEvent.Kind.resize.rawValue == 3)
        #expect(CmuxTUIRenderEvent.Kind.ready.rawValue == 4)
        #expect(CmuxTUIRenderEvent.Kind.exit.rawValue == 5)
    }
}

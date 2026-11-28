#if canImport(UIKit)
import Foundation
import Testing
@testable import CmuxMobileTerminal

@Suite("Ghostty surface callbacks")
struct GhosttySurfaceCallbackTests {
    @Test("libghostty surface callbacks can run off the main thread")
    func ghosttySurfaceCallbacksRunOffMainThread() async {
        let bridge = GhosttySurfaceBridge()
        let userdata = Unmanaged.passRetained(bridge).toOpaque()
        let userdataAddress = UInt(bitPattern: userdata)
        defer { GhosttySurfaceBridge.releaseRetainedOpaque(userdata) }

        let ranOnMainThread = await withCheckedContinuation { continuation in
            DispatchQueue(label: "dev.cmux.tests.ghostty-surface-callback").async {
                let callbackUserdata = UnsafeMutableRawPointer(bitPattern: userdataAddress)
                let bytes = Array("focus".utf8CString)
                bytes.withUnsafeBufferPointer { buffer in
                    GhosttySurfaceBridge.ioWriteCallback(
                        callbackUserdata,
                        buffer.baseAddress,
                        UInt(max(buffer.count - 1, 0))
                    )
                }
                GhosttySurfaceBridge.renderPresentedCallback(callbackUserdata, 42)
                continuation.resume(returning: Thread.isMainThread)
            }
        }

        #expect(!ranOnMainThread)
    }
}
#endif

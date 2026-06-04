import Foundation
@testable import CmuxMobileGhosttyEngine

/// Records every backend call in order so tests can assert the session's
/// FIFO + dispose-last guarantees without linking libghostty.
///
/// `@unchecked Sendable` justification: calls arrive on the session's serial
/// executor while assertions run on the test thread; every mutable property
/// is guarded by `lock` (test scaffolding, where locks are sanctioned).
final class ScriptedSurfaceBackend: GhosttySurfaceControlling, @unchecked Sendable {
    enum Call: Equatable {
        case processOutput(String)
        case renderNow
        case bindingAction(String)
        case textInput(String)
        case pasteText(String)
        case setSize(UInt32, UInt32)
        case setContentScale(Double)
        case measuredSize
        case readText(GhosttySurfaceTextScope)
        case completeClipboardRequest(String)
        case free
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var measuredSizes: [GhosttySurfaceMeasuredSize]
    private let fallbackMeasuredSize: GhosttySurfaceMeasuredSize
    var scriptedText: String?

    init(
        measuredSizes: [GhosttySurfaceMeasuredSize] = [],
        fallback: GhosttySurfaceMeasuredSize = GhosttySurfaceMeasuredSize(
            columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 480
        )
    ) {
        self.measuredSizes = measuredSizes
        fallbackMeasuredSize = fallback
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    private func record(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }

    func processOutput(_ data: Data) {
        record(.processOutput(String(decoding: data, as: UTF8.self)))
    }

    func renderNow() { record(.renderNow) }

    func performBindingAction(_ action: String) { record(.bindingAction(action)) }

    func sendTextInput(_ text: String) { record(.textInput(text)) }

    func sendPasteText(_ text: String) { record(.pasteText(text)) }

    func setSize(pixelWidth: UInt32, pixelHeight: UInt32) {
        record(.setSize(pixelWidth, pixelHeight))
    }

    func setContentScale(_ x: Double, _ y: Double) { record(.setContentScale(x)) }

    func measuredSize() -> GhosttySurfaceMeasuredSize {
        record(.measuredSize)
        lock.lock()
        defer { lock.unlock() }
        if measuredSizes.isEmpty {
            return fallbackMeasuredSize
        }
        return measuredSizes.removeFirst()
    }

    func readText(_ scope: GhosttySurfaceTextScope) -> String? {
        record(.readText(scope))
        return scriptedText
    }

    func processExited() -> Bool { false }

    func setFocus(_ focused: Bool) {}

    func setOcclusion(visible: Bool) {}

    func imePoint() -> GhosttySurfaceIMEPoint {
        GhosttySurfaceIMEPoint(x: 0, y: 0, width: 0, height: 0)
    }

    func completeClipboardRequest(text: String, stateBits: Int) {
        record(.completeClipboardRequest(text))
    }

    func free() { record(.free) }
}

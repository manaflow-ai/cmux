#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import Darwin

@_silgen_name("swift_demangle")
private func layoutMarkDiagDemangle(_ name: UnsafePointer<CChar>?, _ length: UInt, _ buffer: UnsafeMutablePointer<CChar>?,
                                    _ size: UnsafeMutablePointer<UInt>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

/// RESIZE P0 7 diagnostic (no merge, branch diag/resize-p0-7-marks-nomerge): per display frame of a `debug.frames` read,
/// who marks views for layout (`needsLayout = true` with its call stack), which classes lay out, and who starts each window
/// layout pass. Heavy frames (2+ window passes, 25+ view layouts or 7+ ms main) and the first spring-like frames are kept;
/// their stacks are symbolized only when the read replies (`diag_frames` in the reply).
@MainActor
public final class LayoutMarkDiag {

    private struct Mark: Hashable {
        var viewClass: String
        var stack: [UInt]
    }

    private struct Frame {
        var index: Int
        var mainMs: Double
        var viewLayouts: Int
        var passes: Int
        var layouts: [String: Int]
        var marks: [Mark: Int]
        var passStacks: [[UInt]]
    }

    private var recording = false
    private var layouts: [String: Int] = [:]
    private var marks: [Mark: Int] = [:]
    private var markCount = 0
    private var passStacks: [[UInt]] = []
    private var passDepth = 0
    private var laidOutCount = 0
    private var passStart: (stack: [UInt], laid: Int)?
    private var kept: [Frame] = []
    private var typicalKept = 0
    static let marksPerFrame = 96
    static let keptFrames = 40
    static let typicalFrames = 8

    public init() {}

    public func start() {
        reset()
        recording = true
    }

    public func stop() { recording = false }

    public func reset() {
        layouts.removeAll()
        marks.removeAll()
        markCount = 0
        passStacks.removeAll()
        kept.removeAll()
        typicalKept = 0
    }

    /// One display frame ended: keep it when heavy, then start the next frame's record.
    public func frame(index: Int, mainMs: Double, viewLayouts: Int, passes: Int) {
        guard recording else { return }
        let heavy = passes >= 2 || viewLayouts >= 25 || mainMs >= 7
        let typical = !heavy && viewLayouts >= 10 && typicalKept < Self.typicalFrames
        if (heavy || typical), kept.count < Self.keptFrames {
            if typical { typicalKept += 1 }
            kept.append(Frame(index: index, mainMs: mainMs, viewLayouts: viewLayouts, passes: passes, layouts: layouts,
                              marks: marks, passStacks: passStacks))
        }
        layouts.removeAll(keepingCapacity: true)
        marks.removeAll(keepingCapacity: true)
        markCount = 0
        passStacks.removeAll(keepingCapacity: true)
    }

    /// The kept frames, symbolized.
    public func report() -> [[String: Any]] {
        var cache: [UInt: String] = [:]
        func symbol(_ address: UInt) -> String {
            if let known = cache[address] { return known }
            var info = Dl_info()
            var text = String(format: "0x%lx", address)
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? ""
                if let name = info.dli_sname {
                    var demangled = String(cString: name)
                    if let out = layoutMarkDiagDemangle(name, UInt(strlen(name)), nil, nil, 0) {
                        demangled = String(cString: out)
                        free(out)
                    }
                    text = "\(image): \(demangled.prefix(200))"
                } else {
                    text = "\(image): \(text)"
                }
            }
            cache[address] = text
            return text
        }
        return kept.map { frame in
            let marks = frame.marks.sorted { $0.value > $1.value }.prefix(40).map { entry -> [String: Any] in
                ["class": entry.key.viewClass, "n": entry.value, "stack": entry.key.stack.map(symbol)]
            }
            return ["i": frame.index, "main_ms": frame.mainMs, "view_layouts": frame.viewLayouts, "passes": frame.passes,
                    "layouts": frame.layouts, "marks": marks, "pass_stacks": frame.passStacks.map { $0.map(symbol) }]
        }
    }

    func marked(_ view: NSView) {
        guard recording, markCount < Self.marksPerFrame else { return }
        markCount += 1
        let stack = Thread.callStackReturnAddresses.dropFirst(2).prefix(22).map { $0.uintValue }
        marks[Mark(viewClass: String(describing: type(of: view)), stack: Array(stack)), default: 0] += 1
    }

    func laidOut(_ view: NSView) {
        guard recording else { return }
        laidOutCount &+= 1
        layouts[String(describing: type(of: view)), default: 0] += 1
    }

    func passWillBegin() {
        passDepth += 1
        guard recording, passDepth == 1, passStacks.count < 6 else { return }
        passStart = (Thread.callStackReturnAddresses.dropFirst(2).prefix(24).map { $0.uintValue }, laidOutCount)
    }

    func passDidEnd() {
        passDepth = max(0, passDepth - 1)
        guard passDepth == 0, let start = passStart else { return }
        passStart = nil
        if laidOutCount != start.laid { passStacks.append(start.stack) }
    }
}
#endif

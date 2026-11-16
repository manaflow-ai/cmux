import AppKit
import CmuxNextWakeups
import Darwin
import Foundation
import os

public struct LaunchRecordWindowSnapshot: Sendable {
    public var id: String
    public var frame: CGRect
    public var displayID: UInt32
    public var backgroundRGBA: [UInt8]
    public var barRGBA: [UInt8]
    public var imagePath: String
    public var imagePixelSize: (width: UInt32, height: UInt32)
    public var workspaceID: String
    public var tabIDs: [String]

    public init(id: String, frame: CGRect, displayID: UInt32 = 0, backgroundRGBA: [UInt8] = [0, 0, 0, 255],
                barRGBA: [UInt8] = [0, 0, 0, 255], imagePath: String = "", imagePixelSize: (UInt32, UInt32) = (0, 0),
                workspaceID: String = "", tabIDs: [String] = []) {
        self.id = id; self.frame = frame; self.displayID = displayID
        self.backgroundRGBA = backgroundRGBA; self.barRGBA = barRGBA; self.imagePath = imagePath
        self.imagePixelSize = imagePixelSize; self.workspaceID = workspaceID; self.tabIDs = tabIDs
    }
}

public struct LaunchRecordSidebarSnapshot: Sendable {
    public var id: String, title: String, iconKey: String
    public init(id: String, title: String, iconKey: String) { self.id = id; self.title = title; self.iconKey = iconKey }
}

public struct LaunchRecordSnapshot: Sendable {
    public var windows: [LaunchRecordWindowSnapshot]
    public var sidebarRows: [LaunchRecordSidebarSnapshot]
    public var sessionSocketPath: String
    public init(windows: [LaunchRecordWindowSnapshot] = [], sidebarRows: [LaunchRecordSidebarSnapshot] = [], sessionSocketPath: String = "") {
        self.windows = windows; self.sidebarRows = sidebarRows; self.sessionSocketPath = sessionSocketPath
    }
}

/// Debounced app-side wiring for the Rust launch-record writer. The snapshot is
/// taken on the main actor; all string allocation and file I/O happen on the files lane.
@MainActor
public final class LaunchRecordWriter {
    public static var current: LaunchRecordWriter?

    private let url: URL
    private let work: BackgroundWork
    private let snapshot: @MainActor () -> LaunchRecordSnapshot
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "launch-record")
    private var timer: Task<Void, Never>?

    public init(url: URL, work: BackgroundWork, snapshot: @escaping @MainActor () -> LaunchRecordSnapshot) {
        self.url = url; self.work = work; self.snapshot = snapshot
    }

    public func schedule() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.enqueue(self.snapshot())
        }
    }

    /// Enqueues a final, shutdown-blocking write from the quit path.
    public func flush() {
        timer?.cancel(); timer = nil
        enqueue(snapshot(), shutdown: .blockShutdown)
    }

    private func enqueue(_ value: LaunchRecordSnapshot, shutdown: ShutdownBehavior = .skipOnShutdown) {
        let url = url, logger = logger
        work.post(.bestEffort, mayBlock: .files, shutdown: shutdown) {
            guard Self.write(value, to: url) else { logger.error("launch record write failed") }
        }
    }

    private static func write(_ value: LaunchRecordSnapshot, to url: URL) -> Bool {
        guard let symbol = dlsym(RTLD_DEFAULT, "cmux_launch_record_write") else { return false }
        typealias Write = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CWindow>?, UInt,
                                          UnsafePointer<CSidebar>?, UInt, UnsafePointer<CChar>?) -> Bool
        let write = unsafeBitCast(symbol, to: Write.self)
        let arena = CStringArena()
        var windows = value.windows.map { window in
            CWindow(frameX: window.frame.origin.x, frameY: window.frame.origin.y, frameWidth: window.frame.width,
                    frameHeight: window.frame.height, displayID: window.displayID, background: window.backgroundRGBA,
                    bar: window.barRGBA, imageWidth: window.imagePixelSize.width, imageHeight: window.imagePixelSize.height,
                    id: arena.put(window.id), image: arena.put(window.imagePath), workspace: arena.put(window.workspaceID),
                    tabs: arena.putPointerArray(window.tabIDs.map(arena.put)), tabCount: window.tabIDs.count)
        }
        let sidebars = value.sidebarRows.map { CSidebar(id: arena.put($0.id), title: arena.put($0.title), icon: arena.put($0.iconKey)) }
        var sidebars = sidebars
        return url.path.withCString { path in
            value.sessionSocketPath.withCString { socket in
                windows.withUnsafeBufferPointer { ws in
                    sidebars.withUnsafeBufferPointer { ss in
                        write(path, ws.baseAddress, UInt(ws.count), ss.baseAddress, UInt(ss.count), socket)
                    }
                }
            }
        }
    }
}

private final class CStringArena: @unchecked Sendable {
    private var allocations: [UnsafeMutableRawPointer] = []
    deinit { allocations.forEach { $0.deallocate() } }
    func put(_ string: String) -> UnsafePointer<CChar> {
        let bytes = Array(string.utf8) + [0]
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: MemoryLayout<CChar>.alignment)
        let pointer = raw.bindMemory(to: CChar.self, capacity: bytes.count)
        for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
        allocations.append(raw); return UnsafePointer(pointer)
    }
    func putPointerArray(_ values: [UnsafePointer<CChar>]) -> UnsafePointer<UnsafePointer<CChar>>? {
        guard !values.isEmpty else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: values.count * MemoryLayout<UnsafePointer<CChar>>.stride, alignment: MemoryLayout<UnsafePointer<CChar>>.alignment)
        let pointer = raw.bindMemory(to: UnsafePointer<CChar>.self, capacity: values.count)
        for (index, value) in values.enumerated() { pointer[index] = value }
        allocations.append(raw)
        return UnsafePointer(pointer)
    }
}

private struct CWindow {
    var frameX, frameY, frameWidth, frameHeight: Double
    var displayID: UInt32
    var backgroundRGBA: (UInt8, UInt8, UInt8, UInt8)
    var barRGBA: (UInt8, UInt8, UInt8, UInt8)
    var imageWidth, imageHeight: UInt32
    var id, image, workspace: UnsafePointer<CChar>
    var visibleTabIDs: UnsafePointer<UnsafePointer<CChar>>?
    var visibleTabCount: UInt
    init(frameX: Double, frameY: Double, frameWidth: Double, frameHeight: Double, displayID: UInt32, background: [UInt8], bar: [UInt8], imageWidth: UInt32, imageHeight: UInt32, id: UnsafePointer<CChar>, image: UnsafePointer<CChar>, workspace: UnsafePointer<CChar>, tabs: UnsafePointer<UnsafePointer<CChar>>?, tabCount: Int) {
        self.frameX = frameX; self.frameY = frameY; self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.displayID = displayID
        let bg = Array((background + [0, 0, 0, 255])[0..<4]), br = Array((bar + [0, 0, 0, 255])[0..<4])
        self.backgroundRGBA = (bg[0], bg[1], bg[2], bg[3]); self.barRGBA = (br[0], br[1], br[2], br[3])
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.id = id; self.image = image; self.workspace = workspace
        self.visibleTabIDs = tabs; self.visibleTabCount = UInt(tabCount)
    }
}

private struct CSidebar { var id, title, icon: UnsafePointer<CChar> }

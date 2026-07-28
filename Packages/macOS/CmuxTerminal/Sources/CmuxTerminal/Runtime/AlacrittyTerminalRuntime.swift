internal import AppKit
internal import Darwin
internal import Foundation

private struct AlacrittyFFICallbacks {
    var userData: UnsafeMutableRawPointer?
    var wake: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    var title: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void)?
    var childExit: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Void)?
}

private struct AlacrittyFFISurfaceConfig {
    var nsView: UnsafeMutableRawPointer?
    var widthPixels: UInt32
    var heightPixels: UInt32
    var scaleFactor: Float
    var appearance: UnsafePointer<CChar>?
    var workingDirectory: UnsafePointer<CChar>?
    var command: UnsafePointer<CChar>?
    var environment: UnsafePointer<CChar>?
    var callbacks: AlacrittyFFICallbacks
}

private final class AlacrittyTerminalCallbackBox: @unchecked Sendable {
    let wake: @MainActor @Sendable () -> Void
    let title: @MainActor @Sendable (String) -> Void
    let childExit: @MainActor @Sendable (Int32) -> Void

    init(
        wake: @escaping @MainActor @Sendable () -> Void,
        title: @escaping @MainActor @Sendable (String) -> Void,
        childExit: @escaping @MainActor @Sendable (Int32) -> Void
    ) {
        self.wake = wake
        self.title = title
        self.childExit = childExit
    }
}

private let alacrittyWakeCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    userData in
    guard let userData else { return }
    let callback = Unmanaged<AlacrittyTerminalCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .wake
    Task { @MainActor in callback() }
}

private let alacrittyTitleCallback:
    @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = {
        userData,
        bytes,
        length in
        guard let userData else { return }
        let title: String
        if let bytes, length > 0 {
            title = String(
                decoding: UnsafeBufferPointer(start: bytes, count: length),
                as: UTF8.self
            )
        } else {
            title = ""
        }
        let callback = Unmanaged<AlacrittyTerminalCallbackBox>
            .fromOpaque(userData)
            .takeUnretainedValue()
            .title
        Task { @MainActor in callback(title) }
    }

private let alacrittyChildExitCallback:
    @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = {
        userData,
        exitCode in
        guard let userData else { return }
        let callback = Unmanaged<AlacrittyTerminalCallbackBox>
            .fromOpaque(userData)
            .takeUnretainedValue()
            .childExit
        Task { @MainActor in callback(exitCode) }
    }

protocol AlacrittyTerminalRuntimeProtocol: AnyObject {
    func updateAppearance(_ appearance: TerminalRuntimeAppearance) -> Bool
    func close()
    func draw() -> Bool
    func resize(
        widthPixels: UInt32,
        heightPixels: UInt32,
        scaleFactor: CGFloat
    ) -> Bool
    func write(_ data: Data) -> Bool
    func sendKey(
        _ key: AlacrittyTerminalKey,
        modifiers: AlacrittyTerminalModifiers
    ) -> Bool
    func scroll(lines: Int32) -> Bool
    func setFocus(_ focused: Bool) -> Bool
    func screenText(includeScrollback: Bool) -> String?
    var processExited: Bool { get }
    var needsConfirmClose: Bool { get }
    var childPID: UInt32 { get }
    func gridSize() -> (
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    )?
    var isRendererRealized: Bool { get }
    func setRendererRealized(_ realized: Bool) -> Bool
}

/// One Alacritty core, PTY loop, and OpenGL renderer instance.
///
/// The Rust dylib owns synchronization for terminal state. cmux invokes
/// renderer functions on the main thread because the embedded target is an
/// AppKit `NSView`.
final class AlacrittyTerminalRuntime: AlacrittyTerminalRuntimeProtocol {
    private let library: AlacrittyTerminalLibrary
    private var handle: UnsafeMutableRawPointer?
    private var callbackBox: Unmanaged<AlacrittyTerminalCallbackBox>?

    private init(
        library: AlacrittyTerminalLibrary,
        handle: UnsafeMutableRawPointer,
        callbackBox: Unmanaged<AlacrittyTerminalCallbackBox>
    ) {
        self.library = library
        self.handle = handle
        self.callbackBox = callbackBox
    }

    deinit {
        close()
    }

    static func create(
        view: NSView,
        widthPixels: UInt32,
        heightPixels: UInt32,
        scaleFactor: CGFloat,
        appearance: TerminalRuntimeAppearance,
        workingDirectory: String?,
        command: String?,
        environment: [String: String],
        wake: @escaping @MainActor @Sendable () -> Void,
        title: @escaping @MainActor @Sendable (String) -> Void,
        childExit: @escaping @MainActor @Sendable (Int32) -> Void
    ) throws -> AlacrittyTerminalRuntime {
        guard let library = AlacrittyTerminalLibrary.shared else {
            throw AlacrittyTerminalRuntimeError.libraryUnavailable
        }
        let environmentData = try JSONSerialization.data(
            withJSONObject: environment,
            options: [.sortedKeys]
        )
        guard let environmentString = String(data: environmentData, encoding: .utf8) else {
            throw AlacrittyTerminalRuntimeError.invalidEnvironment
        }
        let appearanceString = try encodedAppearance(appearance)

        let callbackBox = Unmanaged.passRetained(AlacrittyTerminalCallbackBox(
            wake: wake,
            title: title,
            childExit: childExit
        ))
        let callbacks = AlacrittyFFICallbacks(
            userData: callbackBox.toOpaque(),
            wake: alacrittyWakeCallback,
            title: alacrittyTitleCallback,
            childExit: alacrittyChildExitCallback
        )

        let handle = appearanceString.withCString { appearancePointer in
            withOptionalCString(workingDirectory) { workingDirectoryPointer in
                withOptionalCString(command) { commandPointer in
                    environmentString.withCString { environmentPointer in
                        var config = AlacrittyFFISurfaceConfig(
                            nsView: Unmanaged.passUnretained(view).toOpaque(),
                            widthPixels: max(widthPixels, 1),
                            heightPixels: max(heightPixels, 1),
                            scaleFactor: Float(max(scaleFactor, 1)),
                            appearance: appearancePointer,
                            workingDirectory: workingDirectoryPointer,
                            command: commandPointer,
                            environment: environmentPointer,
                            callbacks: callbacks
                        )
                        return withUnsafePointer(to: &config) { configPointer in
                            library.createSurface(UnsafeRawPointer(configPointer))
                        }
                    }
                }
            }
        }
        guard let handle else {
            callbackBox.release()
            throw AlacrittyTerminalRuntimeError.creationFailed(library.lastError())
        }
        return AlacrittyTerminalRuntime(
            library: library,
            handle: handle,
            callbackBox: callbackBox
        )
    }

    func updateAppearance(_ appearance: TerminalRuntimeAppearance) -> Bool {
        guard let handle,
              let appearanceString = try? Self.encodedAppearance(appearance) else {
            return false
        }
        return appearanceString.withCString { appearancePointer in
            library.updateAppearance(handle, appearancePointer)
        }
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        library.freeSurface(handle)
        callbackBox?.release()
        callbackBox = nil
    }

    func draw() -> Bool {
        guard let handle else { return false }
        return library.drawSurface(handle)
    }

    var isRendererRealized: Bool {
        guard let handle else { return false }
        return library.rendererRealized(handle)
    }

    func setRendererRealized(_ realized: Bool) -> Bool {
        guard let handle else { return false }
        return library.setRendererRealized(handle, realized)
    }

    func resize(
        widthPixels: UInt32,
        heightPixels: UInt32,
        scaleFactor: CGFloat
    ) -> Bool {
        guard let handle else { return false }
        return library.resizeSurface(
            handle,
            max(widthPixels, 1),
            max(heightPixels, 1),
            Float(max(scaleFactor, 1))
        )
    }

    func write(_ data: Data) -> Bool {
        guard let handle else { return false }
        return data.withUnsafeBytes { bytes in
            library.writeSurface(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
    }

    func sendKey(_ key: AlacrittyTerminalKey, modifiers: AlacrittyTerminalModifiers = []) -> Bool {
        guard let handle else { return false }
        return library.sendKey(handle, key.rawValue, modifiers.rawValue)
    }

    func scroll(lines: Int32) -> Bool {
        guard let handle else { return false }
        return library.scrollSurface(handle, lines)
    }

    func setFocus(_ focused: Bool) -> Bool {
        guard let handle else { return false }
        return library.setFocus(handle, focused)
    }

    func screenText(includeScrollback: Bool = false) -> String? {
        guard let handle else { return nil }
        var length = 0
        guard let pointer = library.screenText(handle, includeScrollback, &length) else {
            return nil
        }
        defer { library.freeString(pointer) }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: length),
            as: UTF8.self
        )
    }

    var processExited: Bool {
        guard let handle else { return true }
        return library.processExited(handle)
    }

    var needsConfirmClose: Bool {
        guard let handle else { return false }
        return library.needsConfirmClose(handle)
    }

    var childPID: UInt32 {
        guard let handle else { return 0 }
        return library.childPID(handle)
    }

    func gridSize() -> (
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    )? {
        guard let handle else { return nil }
        var columns: UInt32 = 0
        var rows: UInt32 = 0
        var cellWidth: UInt32 = 0
        var cellHeight: UInt32 = 0
        guard library.gridSize(
            handle,
            &columns,
            &rows,
            &cellWidth,
            &cellHeight
        ) else {
            return nil
        }
        return (
            Int(columns),
            Int(rows),
            Int(cellWidth),
            Int(cellHeight)
        )
    }

    private static func encodedAppearance(
        _ appearance: TerminalRuntimeAppearance
    ) throws -> String {
        let data = try JSONEncoder().encode(appearance)
        return String(decoding: data, as: UTF8.self)
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else { return body(nil) }
        return value.withCString(body)
    }
}

enum AlacrittyTerminalKey: UInt32 {
    case enter = 0
    case tab = 1
    case backspace = 2
    case escape = 3
    case up = 4
    case down = 5
    case left = 6
    case right = 7
    case home = 8
    case end = 9
    case pageUp = 10
    case pageDown = 11
    case delete = 12
    case insert = 13
    case f1 = 14
    case f2 = 15
    case f3 = 16
    case f4 = 17
    case f5 = 18
    case f6 = 19
    case f7 = 20
    case f8 = 21
    case f9 = 22
    case f10 = 23
    case f11 = 24
    case f12 = 25
}

struct AlacrittyTerminalModifiers: OptionSet, Sendable {
    let rawValue: UInt32

    static let shift = AlacrittyTerminalModifiers(rawValue: 1 << 0)
    static let control = AlacrittyTerminalModifiers(rawValue: 1 << 1)
    static let option = AlacrittyTerminalModifiers(rawValue: 1 << 2)
}

private enum AlacrittyTerminalRuntimeError: LocalizedError {
    case libraryUnavailable
    case invalidEnvironment
    case creationFailed(String?)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            "Alacritty terminal library is unavailable"
        case .invalidEnvironment:
            "Alacritty terminal environment could not be encoded"
        case .creationFailed(let detail):
            detail.map { "Alacritty terminal creation failed: \($0)" }
                ?? "Alacritty terminal creation failed"
        }
    }
}

private final class AlacrittyTerminalLibrary: @unchecked Sendable {
    fileprivate typealias CreateSurface = @convention(c) (
        UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    fileprivate typealias FreeSurface = @convention(c) (UnsafeMutableRawPointer?) -> Void
    fileprivate typealias DrawSurface = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    fileprivate typealias ResizeSurface = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32,
        UInt32,
        Float
    ) -> Bool
    fileprivate typealias UpdateAppearance = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?
    ) -> Bool
    fileprivate typealias SetRendererRealized = @convention(c) (
        UnsafeMutableRawPointer?,
        Bool
    ) -> Bool
    fileprivate typealias RendererRealized = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Bool
    fileprivate typealias WriteSurface = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<UInt8>?,
        Int
    ) -> Bool
    fileprivate typealias SendKey = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32,
        UInt32
    ) -> Bool
    fileprivate typealias ScrollSurface = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32
    ) -> Bool
    fileprivate typealias SetFocus = @convention(c) (
        UnsafeMutableRawPointer?,
        Bool
    ) -> Bool
    fileprivate typealias ScreenText = @convention(c) (
        UnsafeMutableRawPointer?,
        Bool,
        UnsafeMutablePointer<Int>?
    ) -> UnsafeMutablePointer<CChar>?
    fileprivate typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    fileprivate typealias ChildPID = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    fileprivate typealias ProcessExited = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    fileprivate typealias NeedsConfirmClose = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    fileprivate typealias GridSize = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?
    ) -> Bool
    fileprivate typealias LastError = @convention(c) () -> UnsafePointer<CChar>?

    static let shared = loadDefault()

    private let dynamicLibraryHandle: UnsafeMutableRawPointer
    fileprivate let createSurface: CreateSurface
    fileprivate let freeSurface: FreeSurface
    fileprivate let drawSurface: DrawSurface
    fileprivate let resizeSurface: ResizeSurface
    fileprivate let updateAppearance: UpdateAppearance
    fileprivate let setRendererRealized: SetRendererRealized
    fileprivate let rendererRealized: RendererRealized
    fileprivate let writeSurface: WriteSurface
    fileprivate let sendKey: SendKey
    fileprivate let scrollSurface: ScrollSurface
    fileprivate let setFocus: SetFocus
    fileprivate let screenText: ScreenText
    fileprivate let freeString: FreeString
    fileprivate let childPID: ChildPID
    fileprivate let processExited: ProcessExited
    fileprivate let needsConfirmClose: NeedsConfirmClose
    fileprivate let gridSize: GridSize
    private let lastErrorFunction: LastError

    private init(
        dynamicLibraryHandle: UnsafeMutableRawPointer,
        createSurface: CreateSurface,
        freeSurface: FreeSurface,
        drawSurface: DrawSurface,
        resizeSurface: ResizeSurface,
        updateAppearance: UpdateAppearance,
        setRendererRealized: SetRendererRealized,
        rendererRealized: RendererRealized,
        writeSurface: WriteSurface,
        sendKey: SendKey,
        scrollSurface: ScrollSurface,
        setFocus: SetFocus,
        screenText: ScreenText,
        freeString: FreeString,
        childPID: ChildPID,
        processExited: ProcessExited,
        needsConfirmClose: NeedsConfirmClose,
        gridSize: GridSize,
        lastErrorFunction: LastError
    ) {
        self.dynamicLibraryHandle = dynamicLibraryHandle
        self.createSurface = createSurface
        self.freeSurface = freeSurface
        self.drawSurface = drawSurface
        self.resizeSurface = resizeSurface
        self.updateAppearance = updateAppearance
        self.setRendererRealized = setRendererRealized
        self.rendererRealized = rendererRealized
        self.writeSurface = writeSurface
        self.sendKey = sendKey
        self.scrollSurface = scrollSurface
        self.setFocus = setFocus
        self.screenText = screenText
        self.freeString = freeString
        self.childPID = childPID
        self.processExited = processExited
        self.needsConfirmClose = needsConfirmClose
        self.gridSize = gridSize
        self.lastErrorFunction = lastErrorFunction
    }

    deinit {
        dlclose(dynamicLibraryHandle)
    }

    fileprivate func lastError() -> String? {
        lastErrorFunction().map { String(cString: $0) }
    }

    private static func loadDefault() -> AlacrittyTerminalLibrary? {
        for path in defaultLibraryPaths() where FileManager.default.fileExists(atPath: path) {
            if let library = load(path: path) {
                return library
            }
        }
        return nil
    }

    private static func load(path: String) -> AlacrittyTerminalLibrary? {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard
            let createSurface = symbol(
                "cmux_alacritty_surface_new",
                from: handle,
                as: CreateSurface.self
            ),
            let freeSurface = symbol(
                "cmux_alacritty_surface_free",
                from: handle,
                as: FreeSurface.self
            ),
            let drawSurface = symbol(
                "cmux_alacritty_surface_draw",
                from: handle,
                as: DrawSurface.self
            ),
            let resizeSurface = symbol(
                "cmux_alacritty_surface_resize",
                from: handle,
                as: ResizeSurface.self
            ),
            let updateAppearance = symbol(
                "cmux_alacritty_surface_update_appearance",
                from: handle,
                as: UpdateAppearance.self
            ),
            let setRendererRealized = symbol(
                "cmux_alacritty_surface_set_renderer_realized",
                from: handle,
                as: SetRendererRealized.self
            ),
            let rendererRealized = symbol(
                "cmux_alacritty_surface_renderer_realized",
                from: handle,
                as: RendererRealized.self
            ),
            let writeSurface = symbol(
                "cmux_alacritty_surface_write",
                from: handle,
                as: WriteSurface.self
            ),
            let sendKey = symbol(
                "cmux_alacritty_surface_key",
                from: handle,
                as: SendKey.self
            ),
            let scrollSurface = symbol(
                "cmux_alacritty_surface_scroll",
                from: handle,
                as: ScrollSurface.self
            ),
            let setFocus = symbol(
                "cmux_alacritty_surface_set_focus",
                from: handle,
                as: SetFocus.self
            ),
            let screenText = symbol(
                "cmux_alacritty_surface_screen_text",
                from: handle,
                as: ScreenText.self
            ),
            let freeString = symbol(
                "cmux_alacritty_string_free",
                from: handle,
                as: FreeString.self
            ),
            let childPID = symbol(
                "cmux_alacritty_surface_child_pid",
                from: handle,
                as: ChildPID.self
            ),
            let processExited = symbol(
                "cmux_alacritty_surface_process_exited",
                from: handle,
                as: ProcessExited.self
            ),
            let needsConfirmClose = symbol(
                "cmux_alacritty_surface_needs_confirm_close",
                from: handle,
                as: NeedsConfirmClose.self
            ),
            let gridSize = symbol(
                "cmux_alacritty_surface_grid_size",
                from: handle,
                as: GridSize.self
            ),
            let lastError = symbol(
                "cmux_alacritty_last_error",
                from: handle,
                as: LastError.self
            )
        else {
            dlclose(handle)
            return nil
        }

        return AlacrittyTerminalLibrary(
            dynamicLibraryHandle: handle,
            createSurface: createSurface,
            freeSurface: freeSurface,
            drawSurface: drawSurface,
            resizeSurface: resizeSurface,
            updateAppearance: updateAppearance,
            setRendererRealized: setRendererRealized,
            rendererRealized: rendererRealized,
            writeSurface: writeSurface,
            sendKey: sendKey,
            scrollSurface: scrollSurface,
            setFocus: setFocus,
            screenText: screenText,
            freeString: freeString,
            childPID: childPID,
            processExited: processExited,
            needsConfirmClose: needsConfirmClose,
            gridSize: gridSize,
            lastErrorFunction: lastError
        )
    }

    private static func symbol<Symbol>(
        _ name: String,
        from handle: UnsafeMutableRawPointer,
        as _: Symbol.Type
    ) -> Symbol? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: Symbol.self)
    }

    private static func defaultLibraryPaths() -> [String] {
        var paths: [String] = []
        if let environmentPath =
            ProcessInfo.processInfo.environment["CMUX_ALACRITTY_FFI_LIB"],
           !environmentPath.isEmpty {
            paths.append(environmentPath)
        }
        if let privateFrameworksPath = Bundle.main.privateFrameworksPath {
            paths.append(
                URL(fileURLWithPath: privateFrameworksPath)
                    .appendingPathComponent(libraryFileName)
                    .path
            )
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        paths.append(
            sourceRoot
                .appendingPathComponent("Native/AlacrittyTerminalFFI/target/cmux-alacritty-ffi")
                .appendingPathComponent(libraryFileName)
                .path
        )
        paths.append(
            sourceRoot
                .appendingPathComponent(
                    "Native/AlacrittyTerminalFFI/target/aarch64-apple-darwin/release"
                )
                .appendingPathComponent(libraryFileName)
                .path
        )
        paths.append(
            sourceRoot
                .appendingPathComponent(
                    "Native/AlacrittyTerminalFFI/target/x86_64-apple-darwin/release"
                )
                .appendingPathComponent(libraryFileName)
                .path
        )
        return paths
    }

    private static let libraryFileName = "libcmux_alacritty_terminal_ffi.dylib"
}

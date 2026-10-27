public import CoreGraphics
internal import Darwin

/// Lists windows, like `CGWindowListCopyWindowInfo`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): it waits for the window server's reply. List windows off
/// the main thread.
///
/// - Parameters:
///   - option: Which windows to list.
///   - relativeToWindow: The window `option` is relative to, or `kCGNullWindowID`.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `CGWindowListCopyWindowInfo` returns.
@inlinable
public func blockingWindowListCopyWindowInfo(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID,
                                             fileID: StaticString = #fileID, line: UInt = #line) -> CFArray? {
    return blockingCall(.systemCall, fileID: fileID, line: line) { CGWindowListCopyWindowInfo(option, relativeToWindow) }
}

/// Captures windows, like `CGWindowListCreateImage`, as a checked blocking call: the window server
/// composites and copies the image back. The SDK marks the function unavailable in favor of
/// ScreenCaptureKit (which needs the Screen Recording grant even for the app's own windows), so this
/// looks it up at run time. Call it only from the capture helpers, screenshot actions and debug tools
/// (scripts/cmux-next/check-perf-source-guard.py).
///
/// - Parameters:
///   - screenBounds: The area to capture in global display coordinates, or `.null` for the windows' bounds.
///   - listOption: Which windows to capture.
///   - windowID: The window `listOption` is relative to, or `kCGNullWindowID`.
///   - imageOption: How to render the image.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The image, or nil when the capture fails or this macOS has no `CGWindowListCreateImage`.
public func blockingWindowListCreateImage(_ screenBounds: CGRect, _ listOption: CGWindowListOption, _ windowID: CGWindowID,
                                          _ imageOption: CGWindowImageOption,
                                          fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    return blockingCall(.systemCall, fileID: fileID, line: line) { () -> CGImage? in
        // SAFETY: dlsym with RTLD_DEFAULT (-2) looks the name up in the loaded images and returns the function's
        // address or NULL; CreateImage is CGWindowListCreateImage's C signature (CGWindowListOption, CGWindowID and
        // CGWindowImageOption are UInt32), and the image it returns is +1 (a Create call), taken retained once.
        // perf-gate-ok: the capture helpers' seam, for the files check-perf-source-guard.py lists only
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafe unsafeBitCast(symbol, to: CreateImage.self)
        return unsafe create(screenBounds, listOption.rawValue, windowID, imageOption.rawValue)?.takeRetainedValue()
    }
}

/// Captures the windows `windowIDs` together, like `CGWindowListCreateImageFromArray`, as a checked
/// blocking call: the window server composites and copies the image back. Looked up at run time like
/// ``blockingWindowListCreateImage(_:_:_:_:fileID:line:)``.
///
/// - Parameters:
///   - screenBounds: The area to capture in global display coordinates, or `.null` for the windows' bounds.
///   - windowIDs: The windows, topmost first.
///   - imageOption: How to render the image.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The image, or nil when the capture fails or this macOS has no `CGWindowListCreateImageFromArray`.
public func blockingWindowListCreateImageFromArray(_ screenBounds: CGRect, _ windowIDs: [CGWindowID], _ imageOption: CGWindowImageOption,
                                                   fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    return blockingCall(.systemCall, fileID: fileID, line: line) { () -> CGImage? in
        // SAFETY: dlsym with RTLD_DEFAULT (-2) looks the name up in the loaded images and returns the function's
        // address or NULL; CreateImage is CGWindowListCreateImageFromArray's C signature, and the image it returns
        // is +1 (a Create call), taken retained once.
        // perf-gate-ok: the capture helpers' seam, for the files check-perf-source-guard.py lists only
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        let create = unsafe unsafeBitCast(symbol, to: CreateImage.self)
        // The array holds CGWindowID values, not CFNumbers.
        // SAFETY: each value travels in a pointer's bits and is never dereferenced (no callbacks: nil); CFArrayCreate
        // copies the ids.count values out of the array's own storage, lent for the call.
        var ids: [UnsafeRawPointer?] = unsafe windowIDs.map { unsafe UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = unsafe CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        return unsafe create(screenBounds, array, imageOption.rawValue)?.takeRetainedValue()
    }
}

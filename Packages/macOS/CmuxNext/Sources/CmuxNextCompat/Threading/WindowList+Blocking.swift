public import CoreGraphics

/// Lists windows, like `CGWindowListCopyWindowInfo`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``): it waits for the window server's reply. List windows off
/// the main thread; `fileID` and `line` name the caller.
///
/// - Returns: What `CGWindowListCopyWindowInfo` returns.
@inlinable
public func blockingWindowListCopyWindowInfo(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID,
                                             fileID: StaticString = #fileID, line: UInt = #line) -> CFArray? {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return CGWindowListCopyWindowInfo(option, relativeToWindow)
}

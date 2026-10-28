public import CoreGraphics

/// ``blockingWindowListCopyWindowInfo(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWindowListCopyWindowInfo(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID,
                                             _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> CFArray? {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { CGWindowListCopyWindowInfo(option, relativeToWindow) }
}

/// ``blockingWindowListCreateImage(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
public func blockingWindowListCreateImage(_ screenBounds: CGRect, _ listOption: CGWindowListOption, _ windowID: CGWindowID,
                                          _ imageOption: CGWindowImageOption,
                                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    blockingCall(.systemCall, permit, fileID: fileID, line: line) {
        windowListCreateImage(screenBounds, listOption, windowID, imageOption)
    }
}

/// ``blockingWindowListCreateImageFromArray(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
public func blockingWindowListCreateImageFromArray(_ screenBounds: CGRect, _ windowIDs: [CGWindowID], _ imageOption: CGWindowImageOption,
                                                   _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    blockingCall(.systemCall, permit, fileID: fileID, line: line) {
        windowListCreateImageFromArray(screenBounds, windowIDs, imageOption)
    }
}

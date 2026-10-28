public import CoreFoundation
public import ImageIO

/// ``blockingImageSource(url:options:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageSource(url: CFURL, _ permit: borrowing BlockingPermit, options: CFDictionary? = nil,
                                fileID: StaticString = #fileID, line: UInt = #line) -> CGImageSource? {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageSourceCreateWithURL(url, options) }
}

/// ``blockingImageSourceCount(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageSourceCount(_ source: CGImageSource, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageSourceGetCount(source) }
}

/// ``blockingImageSourceCopyProperties(_:at:options:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageSourceCopyProperties(_ source: CGImageSource, at index: Int, _ permit: borrowing BlockingPermit, options: CFDictionary? = nil,
                                              fileID: StaticString = #fileID, line: UInt = #line) -> CFDictionary? {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageSourceCopyPropertiesAtIndex(source, index, options) }
}

/// ``blockingImageSourceCreateImage(_:at:options:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageSourceCreateImage(_ source: CGImageSource, at index: Int, _ permit: borrowing BlockingPermit, options: CFDictionary? = nil,
                                           fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageSourceCreateImageAtIndex(source, index, options) }
}

/// ``blockingImageSourceCreateThumbnail(_:at:options:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageSourceCreateThumbnail(_ source: CGImageSource, at index: Int, _ permit: borrowing BlockingPermit, options: CFDictionary? = nil,
                                               fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageSourceCreateThumbnailAtIndex(source, index, options) }
}

/// ``blockingImageDestination(url:type:count:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageDestination(url: CFURL, type: CFString, count: Int,
                                     _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> CGImageDestination? {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageDestinationCreateWithURL(url, type, count, nil) }
}

/// ``blockingImageDestinationFinalize(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingImageDestinationFinalize(_ destination: CGImageDestination,
                                             _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
    return blockingCall(.fileIO, permit, fileID: fileID, line: line) { CGImageDestinationFinalize(destination) }
}

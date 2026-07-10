import Foundation

/// A lifecycle event for one underlying mobile transport connection attempt.
public enum MobileRPCTransportConnectEvent: Sendable {
    /// The transport factory is about to build and dial its route.
    case attempt
    /// The underlying byte transport connected successfully.
    /// - Parameter elapsedMilliseconds: Whole milliseconds since the attempt began.
    case connected(elapsedMilliseconds: Int)
    /// The transport factory or underlying byte transport failed.
    /// - Parameters:
    ///   - error: The transport construction or connection error.
    ///   - elapsedMilliseconds: Whole milliseconds since the attempt began.
    case failed(error: any Error, elapsedMilliseconds: Int)
}

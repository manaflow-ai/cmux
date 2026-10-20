package import Foundation

/// The lifetime of one parent-owned Native child; stop joins all of its credential work.
package protocol NativeCloudLink: Sendable {
    func socketPath() async throws -> String
    func currentSocketPath() async -> String?
    func stop() async
}

import Foundation
@testable import CmuxNextCloud

actor NativeCloudLinkOwnerChild: NativeCloudLink {
    private let tag: String
    private let world: NativeCloudLinkOwnerWorld
    private var socket: String?
    private var stopped = false
    init(tag: String, world: NativeCloudLinkOwnerWorld) { self.tag = tag; self.world = world }
    func socketPath() async throws -> String {
        guard !stopped else { throw CancellationError() }
        if let socket { return socket }
        await world.start(tag)
        guard !stopped else { throw CancellationError() }
        let path = "/tmp/native-\(tag).sock"
        socket = path
        return path
    }
    func currentSocketPath() -> String? { stopped ? nil : socket }
    func stop() async { stopped = true; socket = nil; await world.stop(tag) }
}

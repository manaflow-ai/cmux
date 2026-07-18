/// The authenticated direction of one renderer-control message.
public enum RendererControlDirection: UInt8, Sendable {
    /// A command sent by cmuxd to one renderer worker.
    case daemonToWorker = 1

    /// A reply sent by one renderer worker to cmuxd.
    case workerToDaemon = 2
}

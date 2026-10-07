/// Receives frames of an attached track (a renderer adapter).
public protocol MediaFrameSink: AnyObject, Sendable {
    func receive(_ frame: MediaFrame)
}

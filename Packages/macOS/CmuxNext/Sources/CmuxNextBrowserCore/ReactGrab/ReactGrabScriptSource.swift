/// Supplies the react-grab library source that ``ReactGrab`` loads into a page.
///
/// ``ReactGrabScriptLoader`` is the production source (the pinned release, fetched once and
/// integrity-checked); tests pass a fixed string.
public nonisolated protocol ReactGrabScriptSource: Sendable {
    /// The library's JavaScript source.
    ///
    /// - Throws: ``ReactGrabError`` or a transport error when the source cannot be produced.
    func script() async throws -> String
}

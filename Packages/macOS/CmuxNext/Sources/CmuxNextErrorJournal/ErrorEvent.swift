public import Foundation

/// One occurrence of a problem, before the journal folds it into an ``ErrorEntry``.
///
/// ```swift
/// ErrorEvent(source: "acpmux", level: .warning, message: "pooled session failed to start")
/// ```
public struct ErrorEvent: Sendable, Equatable {
    /// Where it happened: `app`, `page:<page>`, `acpmux`, `chief`, `crash`, `system:<subsystem>`.
    public var source: String
    /// How bad it is.
    public var level: ErrorLevel
    /// The message as the source wrote it; the journal redacts and bounds it.
    public var message: String
    /// The innermost useful frame (`file:line`, a JS stack line), part of the fingerprint.
    public var topFrame: String?
    /// Small facts kept with the sample (category, file, pid); the journal redacts and bounds them.
    public var context: [String: String]
    /// When it happened.
    public var date: Date

    /// Makes an event.
    /// - Parameters:
    ///   - source: Where it happened.
    ///   - level: How bad it is.
    ///   - message: The raw message.
    ///   - topFrame: The innermost frame, or nil.
    ///   - context: Small facts for the sample.
    ///   - date: When it happened; defaults to now.
    public init(source: String, level: ErrorLevel, message: String, topFrame: String? = nil,
                context: [String: String] = [:], date: Date = Date()) {
        self.source = source
        self.level = level
        self.message = message
        self.topFrame = topFrame
        self.context = context
        self.date = date
    }
}

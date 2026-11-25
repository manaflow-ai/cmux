#if !canImport(AppKit)
public import Foundation

// The few AppKit and os names the action model files use, for the Linux build of the action exports
// (scripts/cmux-next/regenerate-action-exports-linux.sh, Packages/macOS/CmuxNext/LinuxActionExports/sources.txt).
// The Mac build never compiles this file: AppKit is there. Values are AppKit's, so a shortcut's wire
// form and every export are the same bytes on both.

/// AppKit's key event, as far as the model reads it. Linux never makes one.
public nonisolated final class NSEvent: Sendable {
    public struct ModifierFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let capsLock = Self(rawValue: 1 << 16)
        public static let shift = Self(rawValue: 1 << 17)
        public static let control = Self(rawValue: 1 << 18)
        public static let option = Self(rawValue: 1 << 19)
        public static let command = Self(rawValue: 1 << 20)
        public static let numericPad = Self(rawValue: 1 << 21)
        public static let help = Self(rawValue: 1 << 22)
        public static let function = Self(rawValue: 1 << 23)
        public static let deviceIndependentFlagsMask = Self(rawValue: 0xffff_0000)
    }

    public enum EventType: Sendable { case keyDown, keyUp, flagsChanged }

    public let type: EventType
    public let modifierFlags: ModifierFlags
    public let characters: String?
    public let charactersIgnoringModifiers: String?
    public let keyCode: UInt16
    public let isARepeat: Bool

    private init() {
        type = .keyDown; modifierFlags = []; characters = nil; charactersIgnoringModifiers = nil; keyCode = 0; isARepeat = false
    }
}

// AppKit's function-key characters (NSEvent.h), private-use code points from U+F700.
public nonisolated let NSUpArrowFunctionKey = 0xF700
public nonisolated let NSDownArrowFunctionKey = 0xF701
public nonisolated let NSLeftArrowFunctionKey = 0xF702
public nonisolated let NSRightArrowFunctionKey = 0xF703
public nonisolated let NSF1FunctionKey = 0xF704
public nonisolated let NSF35FunctionKey = 0xF726
public nonisolated let NSDeleteFunctionKey = 0xF728
public nonisolated let NSHomeFunctionKey = 0xF729
public nonisolated let NSEndFunctionKey = 0xF72B
public nonisolated let NSPageUpFunctionKey = 0xF72C
public nonisolated let NSPageDownFunctionKey = 0xF72D
public nonisolated let NSClearLineFunctionKey = 0xF739

/// os's Logger: Linux drops the lines (the exporter reports through its exit status and stderr).
public nonisolated struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func debug(_ message: LogMessage) {}
    public func info(_ message: LogMessage) {}
    public func notice(_ message: LogMessage) {}
    public func warning(_ message: LogMessage) {}
    public func error(_ message: LogMessage) { FileHandle.standardError.write(Data((message.text + "\n").utf8)) }
    public func fault(_ message: LogMessage) { FileHandle.standardError.write(Data((message.text + "\n").utf8)) }
}

/// A log line with os's `privacy:` labels, which Linux ignores.
public nonisolated struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    public enum Privacy: Sendable { case `public`, `private`, auto, sensitive }
    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .auto) { text += "\(value)" }
    }
    let text: String
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

nonisolated extension String {
    /// Foundation's localized lookup, which Linux's Foundation lacks: the English default. The exports
    /// take every title from the Rust catalog and the string catalogs, never from this.
    init(localized key: StaticString, defaultValue: String, table: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {
        self = defaultValue
    }
}

nonisolated extension Bundle {
    /// The module's strings bundle (`Bundle+AppLanguage.swift` on the Mac).
    static var localizedModule: Bundle { .main }
}

extension Shortcut {
    /// `ShortcutKeyPositions.swift` on the Mac (Carbon's key codes). Linux never reads a key event.
    nonisolated static func qwertyKey(for event: NSEvent, qwerty: Bool) -> String? { nil }
}
#endif

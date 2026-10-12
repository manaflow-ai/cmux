public import CmuxNextRemoteView
public import CoreGraphics

#if DEBUG
/// A popup surface message from the host (`rb.surface.*`, RT5): a date or
/// color picker, an autofill list or a bubble that Chromium draws in its
/// own widget. It streams on its own rd stream; `anchor` is where it sits
/// in the page, in CSS pixels (its size is the anchor's), and the pixel size
/// is its stream's. The client reducer does not handle these; the session
/// does, before the reducer.
public nonisolated enum RbSurfaceMessage: Sendable, Equatable {
    case show(surface: UInt32, stream: UInt16, kind: String, anchor: CGRect, pixelWidth: Int, pixelHeight: Int)
    case update(surface: UInt32, anchor: CGRect, pixelWidth: Int, pixelHeight: Int)
    case hide(surface: UInt32)

    /// Nil for any other body, and for a surface message missing a field.
    public init?(_ body: RemoteRdJSON) {
        guard case let .object(fields) = body, case let .string(t)? = fields["t"], t.hasPrefix("rb.surface."),
              let surface = Self.integer(fields["surface"]).flatMap({ UInt32(exactly: $0) }) else { return nil }
        switch t {
        case "rb.surface.show":
            guard let stream = Self.integer(fields["stream"]).flatMap({ UInt16(exactly: $0) }),
                  case let .string(kind)? = fields["kind"],
                  let anchor = Self.rect(fields["anchor"]),
                  let width = Self.integer(fields["width"]), let height = Self.integer(fields["height"]) else { return nil }
            self = .show(surface: surface, stream: stream, kind: kind, anchor: anchor, pixelWidth: width, pixelHeight: height)
        case "rb.surface.update":
            guard let anchor = Self.rect(fields["anchor"]),
                  let width = Self.integer(fields["width"]), let height = Self.integer(fields["height"]) else { return nil }
            self = .update(surface: surface, anchor: anchor, pixelWidth: width, pixelHeight: height)
        case "rb.surface.hide":
            self = .hide(surface: surface)
        default:
            return nil
        }
    }

    private static func number(_ value: RemoteRdJSON?) -> Double? {
        switch value {
        case let .int(value)?: Double(value)
        case let .double(value)?: value.isFinite ? value : nil
        default: nil
        }
    }

    private static func integer(_ value: RemoteRdJSON?) -> Int? {
        guard case let .int(value)? = value else { return nil }
        return Int(exactly: value).flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func rect(_ value: RemoteRdJSON?) -> CGRect? {
        guard case let .object(fields)? = value,
              let x = number(fields["x"]), let y = number(fields["y"]),
              let width = number(fields["width"]), let height = number(fields["height"]), width >= 0, height >= 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
#endif

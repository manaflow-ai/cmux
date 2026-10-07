public import AppKit
public import Foundation
public import SwiftUI

/// One named variant of an entry (`variants` in the web format).
public nonisolated struct GalleryVariant: Hashable, Sendable {
    /// Lower kebab case (`pending-single`, `9`).
    public let name: String
    /// One line for the stage header.
    public let note: String?
    public let fixture: GalleryFixture?

    public init(_ name: String, note: String? = nil, fixture: GalleryFixture? = nil) {
        self.name = name
        self.note = note
        self.fixture = fixture
    }
}

/// One gallery entry: the same id, variants and coverage list as a web `*.gallery.ts` entry,
/// and a builder that makes the real view for a variant under the controls. The native
/// gallery host applies the theme, appearance, scale and locale around the view; the builder
/// reads the rest of `GalleryEnvironment` (width, dynamic size, window key) itself.
///
/// ```swift
/// GalleryEntry(id: "home.list-row", title: "List row", area: "Home",
///              covers: ["swift:HomeConversationRowView"],
///              variants: ["default", "unread"].map { GalleryVariant($0, fixture: …) }) { variant, env in
///     HomeConversationRowView(row: try variant.fixture?.decode(HomeRow.self) ?? .sample)
/// }
/// ```
public nonisolated struct GalleryEntry: Sendable {
    /// Dotted lower kebab case (`home.list-row`); unique across both hosts.
    public let id: String
    public let title: String
    /// Sidebar group.
    public let area: String
    /// What the entry shows: `swift:<TypeName>` for native views (the coverage check reads it).
    public let covers: [String]
    public let variants: [GalleryVariant]
    /// Width presets in points (`narrow`, `normal`, `wide`) when the entry's own differ from
    /// ``GalleryEnvironment/nativeWidths``.
    public let widths: [String: Double]?
    private let build: @MainActor @Sendable (GalleryVariant, GalleryEnvironment) throws -> NSView

    /// An AppKit entry.
    public init(
        id: String, title: String, area: String, covers: [String], variants: [GalleryVariant],
        widths: [String: Double]? = nil,
        makeView: @escaping @MainActor @Sendable (GalleryVariant, GalleryEnvironment) throws -> NSView
    ) {
        self.id = id
        self.title = title
        self.area = area
        self.covers = covers
        self.variants = variants
        self.widths = widths
        build = makeView
    }

    /// A SwiftUI entry: the view is hosted in an `NSHostingView`.
    public init<Content: View>(
        id: String, title: String, area: String, covers: [String], variants: [GalleryVariant],
        widths: [String: Double]? = nil,
        @ViewBuilder content: @escaping @MainActor @Sendable (GalleryVariant, GalleryEnvironment) throws -> Content
    ) {
        self.init(id: id, title: title, area: area, covers: covers, variants: variants, widths: widths) { variant, env in
            NSHostingView(rootView: try content(variant, env))
        }
    }

    /// The variant named `name`.
    public func variant(_ name: String) -> GalleryVariant? { variants.first { $0.name == name } }

    /// The real view for `variant` under `environment`.
    @MainActor public func makeView(_ variant: GalleryVariant, environment: GalleryEnvironment) throws -> NSView {
        try build(variant, environment)
    }
}

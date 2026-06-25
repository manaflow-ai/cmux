public import CoreGraphics
public import Foundation
// CmuxFoundation vends the shared `Image.cmuxSymbolRasterSize` helper used by the
// checkmark glyph; internal import since the helper is only used inside `body`.
internal import CmuxFoundation
public import SwiftUI

/// Popover content listing the panel's selectable browser profiles, plus the
/// new/import/rename actions.
///
/// Pure presentation: the app builds a `[BrowserProfileItem]` snapshot (each
/// row's selected state computed app-side against `panel.profileID`), resolves
/// every localized button title from the app bundle, and supplies the four
/// action closures. The popover-presentation `@State` and store access
/// (`BrowserProfileStore`, `canRename`, dialog presentation) stay at the app
/// call site; this view renders only the menu content. Dismissal-on-action is
/// the app's responsibility inside the closures.
///
/// `canRename` gates the rename row; the app computes it from
/// `browserProfileStore.canRenameProfile(id:)`. The localized titles are passed
/// in because the catalog keys (`browser.profile.menu.title`,
/// `browser.profile.new`, `menu.view.importFromBrowser`,
/// `browser.profile.rename`) live in the app bundle, not this package's bundle.
public struct BrowserProfilePopoverView: View {
    private let title: String
    private let items: [BrowserProfileItem]
    private let newProfileTitle: String
    private let importTitle: String
    private let renameTitle: String
    private let canRename: Bool
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let onSelect: (UUID) -> Void
    private let onCreate: () -> Void
    private let onRename: () -> Void
    private let onImport: () -> Void

    /// Creates the browser-profile popover content.
    /// - Parameters:
    ///   - title: App-localized "Profiles" header label.
    ///   - items: One snapshot per selectable profile, with `isSelected`
    ///     precomputed app-side.
    ///   - newProfileTitle: App-localized "New Profile..." button title.
    ///   - importTitle: App-localized "Import Browser Data…" button title.
    ///   - renameTitle: App-localized "Rename Current Profile..." button title.
    ///   - canRename: Whether the rename row is shown.
    ///   - horizontalPadding: App-resolved horizontal content padding.
    ///   - verticalPadding: App-resolved vertical content padding.
    ///   - onSelect: Invoked with the chosen profile id when a row is tapped.
    ///   - onCreate: Invoked when the new-profile button is tapped.
    ///   - onRename: Invoked when the rename button is tapped.
    ///   - onImport: Invoked when the import button is tapped.
    public init(
        title: String,
        items: [BrowserProfileItem],
        newProfileTitle: String,
        importTitle: String,
        renameTitle: String,
        canRename: Bool,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        onSelect: @escaping (UUID) -> Void,
        onCreate: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onImport: @escaping () -> Void
    ) {
        self.title = title
        self.items = items
        self.newProfileTitle = newProfileTitle
        self.importTitle = importTitle
        self.renameTitle = renameTitle
        self.canRename = canRename
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.onSelect = onSelect
        self.onCreate = onCreate
        self.onRename = onRename
        self.onImport = onImport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.isSelected ? "checkmark" : "circle")
                                .cmuxSymbolRasterSize(10, weight: .semibold)
                                .opacity(item.isSelected ? 1.0 : 0.0)
                                .frame(width: 12, alignment: .center)
                            Text(item.name)
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(item.isSelected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button {
                onCreate()
            } label: {
                Text(newProfileTitle)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                onImport()
            } label: {
                Text(importTitle)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            if canRename {
                Button {
                    onRename()
                } label: {
                    Text(renameTitle)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(minWidth: 208)
    }
}

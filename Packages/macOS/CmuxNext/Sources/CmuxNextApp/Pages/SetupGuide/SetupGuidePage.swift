import AppKit
import CmuxNextActions
import CmuxNextDesign
import SwiftUI

extension InternalPageID {
    static let setupGuide = InternalPageID(rawValue: "setup-guide")
}

struct SetupGuideSection: Identifiable {
    let id: String
    let title: String
    let steps: [String]
}

/// Offline instructions from setup::TASKS. Reading the guide never checks credentials or starts a login.
@MainActor
final class SetupGuidePage: InternalPageProvider {
    var page: InternalPageID { .setupGuide }
    var title: String { Self.pageTitle }
    var symbol: String { "book" }
    static var pageTitle: String { String(localized: "setupGuide.title", defaultValue: "Setup Guide", table: "SetupGuide", bundle: .module) }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        NSHostingView(rootView: SetupGuideView())
    }

    static func bind(into registry: ActionRegistry, services: AppServices) {
        services.pages.register(SetupGuidePage())
        registry.bindEffect("help.setupGuide", effect: { [weak services] invocation in
            guard let services, services.pages.show(.setupGuide, in: services.windows.active, focus: invocation.allowsViewChange) != nil else {
                return .refused(RefusalStrings.noWindowOpen)
            }
            return .done
        })
    }
}

/// The same unboxed reading layout as the native Todo page; no status indicators or automatic actions.
struct SetupGuideView: View {
    // The gallery compares the existing spacing scale; the shipped reading layout uses 24/680.
    var sectionSpacing: CGFloat = 24
    var readingWidth: CGFloat = 680
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                Text(SetupGuidePage.pageTitle).font(Font(Typography.title))
                    .accessibilityAddTraits(.isHeader)
                ForEach(SetupGuideContent.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title).font(Font(Typography.bodyEmphasized))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: "\(index + 1).")
                                    .foregroundStyle(.secondary).accessibilityHidden(true)
                                Text(step).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .accessibilityIdentifier("setup-guide-\(section.id)")
                }
            }
            .font(Font(Typography.body))
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("setup-guide")
    }
}

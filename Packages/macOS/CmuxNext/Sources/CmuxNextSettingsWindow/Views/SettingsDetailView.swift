import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// The Settings detail: the selected page or the search results (pages
/// layout), or every section on one page (one-page layout). It follows
/// `SettingsWindowModel.jump`: scrolls the anchor into view, then lets its
/// highlight go (`SettingsHighlightPlan`).
struct SettingsDetailView: View {
    let model: SettingsWindowModel
    let layout: SettingsWindowLayout

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space6) {
                    if let error = model.writeError {
                        Text(error).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.danger)
                            .padding(.top, layout == .onePage ? Metrics.titlebarHeight : 0)
                    }
                    switch layout {
                    case .pages:
                        if model.query.isEmpty {
                            Text(model.selection.title).font(SettingsStyle.title).foregroundStyle(SettingsStyle.text)
                            SettingsSectionView(model: model, section: model.selection)
                        } else {
                            SettingsSearchResultsView(model: model)
                        }
                    case .onePage:
                        SettingsOnePageView(model: model)
                    }
                }
                .padding(.horizontal, Metrics.space6 + Metrics.space4)
                // One page: every header carries the titlebar inset, so a
                // header scrolled to the top sits below the titlebar.
                .padding(.top, layout == .pages ? Metrics.titlebarHeight : 0)
                .padding(.bottom, Metrics.space6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(.named(SettingsOnePageView.coordinateSpace))
            .scrollIndicators(.automatic)
            // No rubber band while the page fits.
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeFade()
            .onChange(of: model.jump?.serial, initial: true) {
                guard let jump = model.jump else { return }
                Task { @MainActor in await follow(jump, proxy: proxy) }
            }
        }
    }

    /// Scrolls to the jump's anchor once its page has laid out, then ends
    /// the highlight: a fade over the Motion `highlight` token, or under
    /// Reduce Motion a hold of the same length and removal in one frame.
    private func follow(_ jump: SettingsJump, proxy: ScrollViewProxy) async {
        await Task.yield()
        guard model.jump?.serial == jump.serial else { return }
        proxy.scrollTo(jump.anchor.id, anchor: jump.anchor.isHeader ? .top : .center)
        guard jump.highlights else { return }
        let plan = model.highlightPlan
        if plan.hold > 0 {
            try? await Task.sleep(for: .seconds(plan.hold))
        }
        // motion-allow: the fade is the Motion highlight token; without one (Reduce Motion, speed off) it goes in one frame
        withAnimation(plan.animates ? Motion.animation(.highlight) : nil) { model.endHighlight(jump) }
    }
}

/// One-page layout: every section stacked under its header. The sidebar
/// follows the scroll position (`SettingsScrollSpy`), and search filters
/// the page in place: non-matching rows, empty groups and sections without
/// a match hide, and the page never switches.
struct SettingsOnePageView: View {
    static let coordinateSpace = "cmux.settings.detail"

    let model: SettingsWindowModel
    /// Header offsets, kept out of the view's state so scrolling does not
    /// rebuild the page.
    @State private var spy = SettingsSpyOffsets()

    var body: some View {
        let filter = model.pageFilter()
        let sections = model.pageSections(filter)
        if sections.isEmpty {
            Text(SettingsWindowStrings.noResults).foregroundStyle(SettingsStyle.secondary)
                .padding(.top, Metrics.titlebarHeight)
        }
        ForEach(sections) { section in
            SettingsPageHeader(section: section) { offset in
                spy.offsets[section] = offset
                let current = SettingsScrollSpy.section(order: sections, offsets: spy.offsets, line: Metrics.titlebarHeight)
                if let current, current != model.selection { model.selection = current }
            }
            SettingsSectionView(model: model, section: section, filter: filter)
        }
    }
}

/// A section's title on the one page; the scroll-spy reads its offset from
/// the top of the visible area.
private struct SettingsPageHeader: View {
    let section: SettingsSection
    let onOffset: (CGFloat) -> Void

    var body: some View {
        Text(section.title).font(SettingsStyle.title).foregroundStyle(SettingsStyle.text)
            .padding(.top, Metrics.titlebarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(SettingsAnchor.header(section).id)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("cmux.settings.detail")).minY
            } action: { offset in
                onOffset(offset)
            }
            .accessibilityAddTraits(.isHeader)
    }
}

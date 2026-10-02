import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import SwiftUI

/// The Settings detail: the selected page or the search results (pages
/// layout), or every section on one page (one-page layout). It follows
/// `SettingsWindowModel.jump`: scrolls the anchor into view, then lets its
/// highlight go (`SettingsHighlightPlan`).
struct SettingsDetailView: View {
    let model: SettingsWindowModel
    let layout: SettingsWindowLayout
    /// The one page's header offsets; shared with the jump so a jump can
    /// keep the scroll-spy from overriding its section.
    @State private var spy = SettingsSpyOffsets()
    @State private var highlightTimer = DemandTimer(owner: "Settings.highlight")

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
                                .id(SettingsAnchor.header(model.selection).id)
                            SettingsSectionView(model: model, section: model.selection)
                        } else {
                            SettingsSearchResultsView(model: model)
                        }
                    case .onePage:
                        SettingsOnePageView(model: model, spy: spy)
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
            // The user scrolling (trackpad, wheel, keys or scroller) moves
            // the page off where the jump left it, which hands the sidebar
            // back to the scroll-spy.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                guard spy.heldByJump else { return }
                // The first offset after a jump is the jump's own scroll.
                guard let settled = spy.heldAt else { return spy.heldAt = offset }
                if abs(offset - settled) > SettingsSpyOffsets.releaseDistance {
                    spy.heldByJump = false
                    spy.heldAt = nil
                }
            }
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
        // The jump picked the section; a centered row, or a last section
        // whose header cannot reach the top, must not hand it to the spy.
        spy.heldByJump = true
        spy.heldAt = nil
        let point: UnitPoint = jump.anchor.isHeader ? .top : .center
        proxy.scrollTo(jump.anchor.id, anchor: point)
        guard jump.highlights else { return }
        let plan = model.highlightPlan
        guard plan.hold > 0 else { return Self.endHighlight(jump, plan: plan, model: model) }
        let model = model
        highlightTimer.schedule(after: .seconds(plan.hold)) { @MainActor in
            SettingsDetailView.endHighlight(jump, plan: plan, model: model)
        }
    }

    private static func endHighlight(_ jump: SettingsJump, plan: SettingsHighlightPlan, model: SettingsWindowModel) {
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
    /// Header offsets, kept out of observed state so scrolling does not
    /// rebuild the page.
    let spy: SettingsSpyOffsets

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
                guard !spy.heldByJump else { return }
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
                // SettingsOnePageView.coordinateSpace, spelled out: this
                // transform runs off the main actor.
                proxy.frame(in: .named("cmux.settings.detail")).minY
            } action: { offset in
                onOffset(offset)
            }
            .accessibilityAddTraits(.isHeader)
    }
}

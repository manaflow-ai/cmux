import CoreGraphics
import SwiftUI

enum SettingsSectionVisibilityCoordinateSpace {
    static let name = "SettingsSectionVisibilityCoordinateSpace"
}

struct SettingsSectionFramePreferenceKey: PreferenceKey {
    static let defaultValue: [SettingsSectionID: CGRect] = [:]

    /// Merges section frames reported by every visibility marker.
    ///
    /// - Parameters:
    ///   - value: Current aggregate section frame map.
    ///   - nextValue: Next lazily produced section frame map from SwiftUI.
    static func reduce(
        value: inout [SettingsSectionID: CGRect],
        nextValue: () -> [SettingsSectionID: CGRect]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

struct SettingsSectionVisibilityMarker: View {
    let section: SettingsSectionID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SettingsSectionFramePreferenceKey.self,
                value: [section: proxy.frame(in: .named(SettingsSectionVisibilityCoordinateSpace.name))]
            )
        }
    }
}

extension View {
    /// Reports this view's frame as the scroll-position marker for a settings section.
    ///
    /// - Parameter section: Section represented by the view.
    /// - Returns: A view that publishes its frame through `SettingsSectionFramePreferenceKey`.
    func settingsSectionVisibility(_ section: SettingsSectionID) -> some View {
        background(SettingsSectionVisibilityMarker(section: section))
    }
}

struct SettingsVisibleSectionResolver: Sendable {
    struct Configuration: Sendable {
        static let defaultActivationY: CGFloat = 0

        let activationY: CGFloat

        /// Creates a resolver configuration.
        ///
        /// - Parameter activationY: Vertical viewport coordinate that decides when
        ///   a section becomes active. A section is active after its top edge
        ///   crosses this coordinate.
        init(activationY: CGFloat = Self.defaultActivationY) {
            self.activationY = activationY
        }
    }

    /// Resolves the section that should be selected for the current scroll position.
    ///
    /// - Parameters:
    ///   - frames: Current section frames in the settings detail scroll coordinate space.
    ///   - orderedSections: Sections in visual scroll order.
    ///   - configuration: Resolver options, including the activation line.
    /// - Returns: The active section, or `nil` when no tracked frames are available.
    static func visibleSection(
        in frames: [SettingsSectionID: CGRect],
        orderedSections: [SettingsSectionID] = SettingsSectionID.allCases,
        configuration: Configuration = Configuration()
    ) -> SettingsSectionID? {
        let orderedFrames = orderedSections.enumerated().compactMap { index, section -> SectionFrame? in
            guard let frame = frames[section] else { return nil }
            return SectionFrame(index: index, section: section, frame: frame)
        }

        guard !orderedFrames.isEmpty else { return nil }

        let containingFrames = orderedFrames.filter {
            $0.frame.minY <= configuration.activationY && $0.frame.maxY >= configuration.activationY
        }
        if let active = nearestFrameToActivationLine(in: containingFrames) {
            return active.section
        }

        let crossedFrames = orderedFrames.filter { $0.frame.minY <= configuration.activationY }
        if let active = nearestFrameToActivationLine(in: crossedFrames) {
            return active.section
        }

        return orderedFrames.min(by: { lhs, rhs in
            if lhs.frame.minY == rhs.frame.minY {
                return lhs.index < rhs.index
            }
            return lhs.frame.minY < rhs.frame.minY
        })?.section
    }

    /// Selects the frame whose top edge is closest to the activation line.
    ///
    /// - Parameter frames: Section frames already filtered to eligible candidates.
    /// - Returns: The nearest eligible frame, or `nil` when no candidates exist.
    private static func nearestFrameToActivationLine(in frames: [SectionFrame]) -> SectionFrame? {
        if let active = frames.max(by: { lhs, rhs in
            if lhs.frame.minY == rhs.frame.minY {
                return lhs.index < rhs.index
            }
            return lhs.frame.minY < rhs.frame.minY
        }) {
            return active
        }
        return nil
    }

    private struct SectionFrame {
        let index: Int
        let section: SettingsSectionID
        let frame: CGRect
    }
}

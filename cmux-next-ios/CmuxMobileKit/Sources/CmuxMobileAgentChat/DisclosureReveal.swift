#if os(iOS)
import CmuxMobileDesign
import SwiftUI

// The transcript's disclosures (a tool group, a tool call's output, a thought) open and close the
// way ChatGPT's "Worked for 56s ›" does (Aziz 2026-10-30, two screen recordings): the line you
// tapped stays where it is on screen, the body grows down from under it, clipped to its growing
// edge while it fades in, and the rows below move down with that edge. Closing plays it backwards.
// Before, the transcript re-pinned to the newest row on each change, so the tapped line jumped, and
// the body appeared at full size while the rows below were still sliding, so they drew over it.

/// Asks the transcript to keep the tapped line where it is drawn while its body opens or closes
/// (`ChatTranscriptController.holdForDisclosure`). A no-op outside the transcript.
struct TranscriptFoldHold {
    /// Holds the tapped line from the tap.
    let begin: @MainActor () -> Void
    /// Lets go when the disclosure's animation completes.
    let end: @MainActor () -> Void
    /// Shows a settling row's SwiftUI view now, in the state it draws before the change (a native
    /// row is swapped for its SwiftUI view at rest), so the change has a view to animate.
    var swap: @MainActor () -> Void = {}
    /// Sizes the rows again on the disclosure's spring: the row's height and the rows below follow
    /// the body's edge instead of jumping to their final places on the next layout pass.
    var resize: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    @Entry var transcriptFoldHold = TranscriptFoldHold(begin: {}, end: {})
}

/// The body's insertion and removal: revealed from the top edge down (a mask the height of the
/// body's progress) while its opacity follows. The rows below move by the body's height on the same
/// animation, so the mask's bottom edge and the next row travel together and never overlap.
struct DisclosureReveal: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .mask(alignment: .top) {
                Rectangle()
                    .frame(maxHeight: phase.isIdentity ? .infinity : 0)
            }
    }
}

extension AnyTransition {
    /// ChatGPT's disclosure body (`DisclosureReveal`).
    static var disclosureReveal: AnyTransition { AnyTransition(DisclosureReveal()) }
}

/// One disclosure tap: the transcript holds the tapped line, the change plays on the shared spring,
/// and the hold ends when that animation completes. Reduce Motion opens and closes at once, and
/// lets go on the next turn of the main loop (after the change is laid out).
///
/// `key` and `disclosures`: the transcript's disclosure (a tool row's `tool-`, a group's `group-`, a
/// thought's `thought-` key). Every such disclosure animates the same way, native or SwiftUI, open
/// or close: its row is SwiftUI while it settles (`ChatDisclosures.settle`), shown in its current
/// state first (`TranscriptFoldHold.swap`); on the next turn of the main loop the change plays on the
/// spring in SwiftUI (the body's `DisclosureReveal`) and in the list (`TranscriptFoldHold.resize`).
@MainActor func toggleDisclosure(_ hold: TranscriptFoldHold, key: String? = nil, in disclosures: ChatDisclosures? = nil,
                                 _ change: @escaping @MainActor () -> Void) {
    hold.begin()
    if UIAccessibility.isReduceMotionEnabled {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
        let end = hold.end
        Task { @MainActor in end() }
        return
    }
    guard let key, let disclosures else {
        withAnimation(.cmuxMobileSmooth, completionCriteria: .logicallyComplete, change) { hold.end() }
        return
    }
    disclosures.settle(key, true)
    hold.swap()
    // After the swapped row drew its current state: a view inserted and changed in one update
    // has no "before" to animate from.
    Task { @MainActor in
        withAnimation(.cmuxMobileSmooth, completionCriteria: .logicallyComplete, change) {
            disclosures.settle(key, false)
            hold.end()
        }
        hold.resize()
    }
}
#endif

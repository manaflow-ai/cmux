import CmuxMobileShellModel
import SwiftUI

/// The network / authentication / trust pairing checklist: one resolving check
/// mark per gate so the user can see exactly which stage of pairing succeeded or
/// failed, instead of one opaque "could not connect"
/// (https://github.com/manaflow-ai/cmux/issues/6084).
///
/// A pure value view — it takes the immutable ``MobilePairingChecklist`` snapshot
/// and renders it, holding no store reference, so it is safe to embed in the
/// pairing form.
struct PairingChecklistRows: View {
    let checklist: MobilePairingChecklist

    var body: some View {
        ForEach(MobilePairingStage.allCases, id: \.self) { stage in
            PairingChecklistRow(stage: stage, status: checklist.status(for: stage))
        }
    }
}

public import CmuxNextDesign
import SwiftUI

/// The plan picker's page (``CloudPlanPicker``): a title, the Monthly/Annual toggle, the Pro, Max and Team cards and
/// the way out (Run on This Mac, Not Now). It fills the window, drawn in the window's theme tokens, light or dark.
/// Layout after Cursor's upgrade gate (cmux-design-references `apps/cursor/live/automations-plan-gate.png`: one
/// centered heading over the choices, quiet chrome around them), with the cards the issue specifies.
struct CloudPlanPickerView: View {
    struct Actions {
        var choose: @MainActor (CloudPlanPicker.Choice) -> Void
        var notNow: @MainActor () -> Void
    }

    @State var picker: CloudPlanPicker
    let palette: CloudPlanPickerPalette
    let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.space5) {
                VStack(spacing: Metrics.space2) {
                    Text(CloudPlanPickerStrings.title)
                        .font(Font(Typography.title))
                        .foregroundStyle(palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(CloudPlanPickerStrings.subtitle)
                        .font(Font(Typography.body))
                        .foregroundStyle(palette.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                intervalToggle
                HStack(alignment: .top, spacing: Metrics.space4) {
                    ForEach(CloudPlanPicker.plans, id: \.id) { plan in
                        CloudPlanCard(plan: plan, picker: picker, palette: palette) { actions.choose(picker.choice(plan)) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.space3) {
                    if picker.offersRunHere {
                        CmuxDialogActionButton(CloudMachineCapCard.Strings.runHere, hint: nil) { actions.choose(.runHere) }
                    }
                    CmuxDialogActionButton(CloudMachineCapCard.Strings.notNow, hint: .escape) { actions.notNow() }
                }
            }
            .padding(Metrics.space6)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CloudPlanPickerStrings.title))
    }

    /// Monthly | Annual (Save 20%): two buttons in one track, the selected one filled.
    private var intervalToggle: some View {
        HStack(spacing: 2) {
            ForEach(CloudPlanPicker.Interval.allCases, id: \.self) { interval in
                let selected = picker.interval == interval
                Button { picker.interval = interval } label: {
                    HStack(spacing: Metrics.space2) {
                        Text(interval == .month ? CloudPlanPickerStrings.monthly : CloudPlanPickerStrings.annual)
                            .font(Font(selected ? Typography.bodyEmphasized : Typography.body))
                        if interval == .year {
                            Text(CloudPlanPickerStrings.save(CloudPlanPicker.bestAnnualSaving))
                                .font(Font(Typography.caption))
                                .foregroundStyle(palette.success)
                        }
                    }
                    .foregroundStyle(selected ? palette.text : palette.secondary)
                    .padding(.horizontal, Metrics.space3)
                    .padding(.vertical, Metrics.space1)
                    .background(RoundedRectangle(cornerRadius: Metrics.controlCornerRadius).fill(selected ? palette.selection : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Metrics.controlCornerRadius + 2).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.controlCornerRadius + 2).stroke(palette.separator))
    }
}

/// One plan: name, price, billing, included usage, its button, what is due today and its machine limits.
private struct CloudPlanCard: View {
    let plan: CloudPlanPicker.Plan
    let picker: CloudPlanPicker
    let palette: CloudPlanPickerPalette
    let choose: () -> Void

    private var recommended: Bool { picker.recommended == plan.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack {
                Text(verbatim: CloudPlanPickerStrings.name(plan.id)).font(Font(Typography.header)).foregroundStyle(palette.text)
                Spacer(minLength: Metrics.space2)
                if recommended {
                    Text(CloudPlanPickerStrings.recommended)
                        .font(Font(Typography.caption))
                        .foregroundStyle(palette.accent)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space1) {
                Text(verbatim: CloudPlanPicker.price(picker.monthlyPrice(plan)))
                    .font(Font(Typography.title))
                    .foregroundStyle(palette.text)
                Text(plan.perSeat ? CloudPlanPickerStrings.perSeatMonth : CloudPlanPickerStrings.perMonth)
                    .font(Font(Typography.body))
                    .foregroundStyle(palette.secondary)
            }
            Text(billingLine).font(Font(Typography.caption)).foregroundStyle(palette.secondary)
            Text(CloudPlanPickerStrings.included(CloudPlanPicker.price(plan.includedUsage), perSeat: plan.perSeat))
                .font(Font(Typography.body))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            CmuxDialogActionButton(CloudPlanPickerStrings.choose(plan.id), hint: recommended ? .return : nil, action: choose)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CloudPlanPickerStrings.today(CloudPlanPicker.price(picker.dueToday(plan))))
                .font(Font(Typography.caption))
                .foregroundStyle(palette.secondary)
            Divider().overlay(palette.separator)
            VStack(alignment: .leading, spacing: Metrics.space2) {
                ForEach(features, id: \.self) { line in
                    Text(line)
                        .font(Font(Typography.body))
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Metrics.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.insetCornerRadius).stroke(recommended ? palette.accent : palette.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: CloudPlanPickerStrings.name(plan.id)))
    }

    private var billingLine: String {
        guard picker.billing(plan) == .year, let yearly = plan.yearly else { return CloudPlanPickerStrings.billedMonthly }
        return CloudPlanPickerStrings.billedYearly(CloudPlanPicker.price(yearly))
    }

    private var features: [String] {
        [CloudPlanPickerStrings.machineSize(cpu: plan.machineCPU, memoryGB: plan.machineMemoryGB),
         CloudPlanPickerStrings.pool(cpu: plan.poolCPU, memoryGB: plan.poolMemoryGB, perSeat: plan.perSeat),
         CloudPlanPickerStrings.machines(plan.machines, perSeat: plan.perSeat),
         CloudPlanPickerStrings.storage(plan.storageGB)]
    }
}

/// The picker's colors, from the theme tokens of the window it fills.
struct CloudPlanPickerPalette: Equatable {
    var text: Color
    var secondary: Color
    var background: Color
    var card: Color
    var selection: Color
    var separator: Color
    var accent: Color
    var success: Color

    init(tokens: ThemeTokens) {
        func color(_ rgb: ThemeRGB) -> Color { Color(nsColor: rgb.nsColor) }
        text = color(tokens.textPrimary)
        secondary = color(tokens.textSecondary)
        background = color(tokens.contentBackground)
        card = color(tokens.chromeBackground)
        selection = color(tokens.selectionFill)
        separator = color(tokens.separator)
        accent = color(tokens.accent)
        success = color(tokens.success)
    }
}

import CmuxSimulator
import SwiftUI

enum SimulatorDeviceQuickControl: CaseIterable, Equatable {
  case home
  case screenshot
  case rotate
  case pointerCapture
  case keyboardCapture

  static func available(for family: SimulatorDeviceFamily?) -> [Self] {
    switch family {
    case .iPad:
      [.home, .screenshot, .rotate, .pointerCapture, .keyboardCapture]
    case .iPhone:
      [.home, .screenshot, .rotate]
    default:
      []
    }
  }
}

struct SimulatorDeviceQuickControls: View {
  let coordinator: SimulatorPaneCoordinator
  let family: SimulatorDeviceFamily?

  var body: some View {
    HStack(spacing: 2) {
      ForEach(SimulatorDeviceQuickControl.available(for: family), id: \.self) { control in
        button(for: control)
      }
    }
    .controlSize(.small)
    .padding(5)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(.primary.opacity(0.16), lineWidth: 1))
    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
  }

  @ViewBuilder
  private func button(for control: SimulatorDeviceQuickControl) -> some View {
    let presentation = presentation(for: control)
    Button(action: presentation.action) {
      Image(systemName: presentation.symbol)
        .font(.system(size: 17, weight: .medium))
        .frame(width: 28, height: 28)
        .background(presentation.isActive ? Color.accentColor.opacity(0.2) : .clear)
        .clipShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!presentation.isEnabled)
    .help(presentation.help)
  }

  private func presentation(
    for control: SimulatorDeviceQuickControl
  ) -> (
    symbol: String, help: LocalizedStringResource, isActive: Bool, isEnabled: Bool,
    action: () -> Void
  ) {
    switch control {
    case .home:
      (
        "house", simulatorStrings.home, false, coordinator.supports(.hardwareButtons),
        {
          coordinator.press(.home)
        }
      )
    case .screenshot:
      (
        "camera.viewfinder", simulatorStrings.screenshot, false, coordinator.status == .streaming,
        {
          coordinator.scheduleControlAction("capture-screenshot") {
            await $0.captureScreenshot(format: .png)
          }
        }
      )
    case .rotate:
      (
        "rotate.left", simulatorStrings.rotateLeft, false, coordinator.supports(.rotation),
        {
          coordinator.rotateLeft()
        }
      )
    case .pointerCapture:
      (
        "cursorarrow.rays",
        simulatorStrings.capturePointer,
        coordinator.hidCaptureMode == .pointerAndKeyboard,
        coordinator.supports(.hostInputCapture),
        {
          coordinator.togglePointerCapture()
        }
      )
    case .keyboardCapture:
      (
        "command",
        simulatorStrings.captureKeyboard,
        coordinator.hidCaptureMode == .keyboard,
        coordinator.supports(.hostInputCapture),
        {
          coordinator.toggleKeyboardCapture()
        }
      )
    }
  }
}

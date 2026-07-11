public import SwiftUI

/// Live Android emulator content and its cmux-owned control rail.
public struct AndroidEmulatorPaneView: View {
    let controller: AndroidEmulatorPaneController
    let isVisible: Bool

    public init(controller: AndroidEmulatorPaneController, isVisible: Bool) {
        self.controller = controller
        self.isVisible = isVisible
    }

    public var body: some View {
        VStack(spacing: 0) {
            AndroidEmulatorPaneHeader(avdName: controller.avdName, serial: controller.serial)
            Divider()
            HStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    AndroidEmulatorCaptureView(
                        controller: controller,
                        isVisible: isVisible && controller.isCaptureReady,
                        sdkRootURL: controller.sdkRootURL,
                        displaySize: controller.displaySize,
                        retryGeneration: controller.captureRetryGeneration
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    if controller.controlsCollapsed {
                        Button {
                            controller.controlsCollapsed = false
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                        .help(String(
                            localized: "androidEmulator.control.show",
                            defaultValue: "Show Controls",
                            bundle: .module
                        ))
                        .padding(8)
                    }
                }
                if !controller.controlsCollapsed {
                    Divider()
                    AndroidEmulatorControlRail(controller: controller)
                }
            }
            if let error = controller.captureError {
                AndroidEmulatorCaptureErrorBanner(error: error, retryAction: controller.retryCapture)
            }
        }
        .background(.black)
        .task { await controller.prepare() }
    }
}

private struct AndroidEmulatorPaneHeader: View {
    let avdName: String
    let serial: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "apps.iphone")
            Text(avdName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(serial)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
    }
}

private struct AndroidEmulatorCaptureErrorBanner: View {
    let error: String
    let retryAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button(String(
                localized: "androidEmulator.capture.retry",
                defaultValue: "Retry",
                bundle: .module
            ), action: retryAction)
            .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }
}

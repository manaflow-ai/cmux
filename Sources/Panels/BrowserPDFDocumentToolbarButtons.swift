import SwiftUI

struct BrowserPDFDocumentToolbarButtons: View {
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat

    var body: some View {
        if panel.renderedPDFDocumentURL != nil {
            Button(action: {
                panel.downloadRenderedPDFDocument()
            }) {
                CmuxSystemSymbolImage(systemName: "square.and.arrow.down", pointSize: iconPointSize, weight: .medium)
                    .frame(width: hitSize, height: hitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .safeHelp(String(localized: "browser.pdf.download", defaultValue: "Download PDF"))
            .accessibilityLabel(String(localized: "browser.pdf.download", defaultValue: "Download PDF"))

            Button(action: {
                panel.printRenderedPDFDocument()
            }) {
                CmuxSystemSymbolImage(systemName: "printer", pointSize: iconPointSize, weight: .medium)
                    .frame(width: hitSize, height: hitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .safeHelp(String(localized: "browser.pdf.print", defaultValue: "Print PDF"))
            .accessibilityLabel(String(localized: "browser.pdf.print", defaultValue: "Print PDF"))
        }
    }
}

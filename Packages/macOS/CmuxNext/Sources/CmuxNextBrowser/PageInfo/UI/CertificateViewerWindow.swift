import AppKit
import CmuxNextDesign
import UniformTypeIdentifiers

/// The certificate viewer: a General tab (Issued To, Issued By,
/// Validity Period, SHA-256 Fingerprints) and a Details tab (hierarchy,
/// fields, field value, Export).
final class CertificateViewerWindow: PageInfoWindow {
    private let chain: [PageInfoCertificate]
    private let tabs = NSSegmentedControl()
    private let container = NSView()
    private var selected = 0

    init(chain: [PageInfoCertificate], site: PageInfoSite, failure: String?) {
        self.chain = chain
        let name = chain.first?.subject.commonName ?? site.host ?? site.displayName
        super.init(title: PageInfoStrings.viewerTitle(name), size: CGSize(width: 520, height: 560))
        setAccessibilityIdentifier("cmux.pageInfo.certificateViewer")
        tabs.segmentCount = 2
        tabs.setLabel(PageInfoStrings.general, forSegment: 0)
        tabs.setLabel(PageInfoStrings.details, forSegment: 1)
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(tabs)
        root.addSubview(container)
        var constraints = [
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: PageInfoStyle.inset),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: PageInfoStyle.inset),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PageInfoStyle.inset * 1.5),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -PageInfoStyle.inset * 1.5),
        ]
        var bottom = root.bottomAnchor
        if let failure {
            let note = PageInfoStyle.label(PageInfoStrings.verificationFailed(failure), font: PageInfoStyle.captionFont,
                                           color: PageInfoStyle.danger, wraps: true)
            root.addSubview(note)
            constraints += [
                note.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                note.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -PageInfoStyle.inset),
            ]
            bottom = note.topAnchor
        }
        constraints.append(container.bottomAnchor.constraint(equalTo: bottom, constant: -PageInfoStyle.inset))
        NSLayoutConstraint.activate(constraints)
        installContent(root)
        showTab(0)
    }

    @objc private func switchTab() { showTab(tabs.selectedSegment) }

    private func showTab(_ index: Int) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        if chain.isEmpty {
            content = PageInfoWindow.valueLabel(PageInfoStrings.noCertificate, selectable: false)
        } else if index == 0 {
            content = generalView(chain[0])
        } else {
            content = CertificateDetailsView(chain: chain)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor).withPriority(index == 0 ? .required : .defaultLow),
        ])
        if index == 1 { content.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true }
    }

    private func generalView(_ certificate: PageInfoCertificate) -> NSView {
        let missing = PageInfoStrings.notPartOfCertificate
        func value(_ text: String?) -> String { text.flatMap { $0.isEmpty ? nil : $0 } ?? missing }
        let dates = DateFormatter()
        dates.dateStyle = .full
        dates.timeStyle = .long
        let sections: [(String, [(String, String)])] = [
            (PageInfoStrings.issuedTo, [
                (PageInfoStrings.commonName, value(certificate.subject.commonName)),
                (PageInfoStrings.organization, value(certificate.subject.organization)),
                (PageInfoStrings.organizationalUnit, value(certificate.subject.organizationalUnit)),
            ]),
            (PageInfoStrings.issuedBy, [
                (PageInfoStrings.commonName, value(certificate.issuer.commonName)),
                (PageInfoStrings.organization, value(certificate.issuer.organization)),
                (PageInfoStrings.organizationalUnit, value(certificate.issuer.organizationalUnit)),
            ]),
            (PageInfoStrings.validityPeriod, [
                (PageInfoStrings.issuedOn, certificate.notBefore.map(dates.string(from:)) ?? missing),
                (PageInfoStrings.expiresOn, certificate.notAfter.map(dates.string(from:)) ?? missing),
            ]),
            (PageInfoStrings.fingerprints, [
                (PageInfoStrings.certificate, certificate.sha256Fingerprint),
                (PageInfoStrings.publicKey, certificate.publicKeySHA256),
            ]),
        ]
        let grid = NSGridView()
        grid.rowSpacing = PageInfoStyle.spacing
        grid.columnSpacing = PageInfoStyle.inset
        for (index, section) in sections.enumerated() {
            if index > 0 { grid.addRow(with: [NSGridCell.emptyContentView]) }
            let title = PageInfoWindow.sectionTitle(section.0)
            let row = grid.addRow(with: [title, NSGridCell.emptyContentView])
            row.mergeCells(in: NSRange(location: 0, length: 2))
            for (label, text) in section.1 {
                let value = PageInfoWindow.valueLabel(text)
                if section.0 == PageInfoStrings.fingerprints { value.font = .monospacedSystemFont(ofSize: PageInfoStyle.captionFont.pointSize, weight: .regular) }
                grid.addRow(with: [PageInfoStyle.label(label, font: PageInfoStyle.bodyFont, color: PageInfoStyle.secondaryText), value])
            }
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).width = 300
        return grid
    }

    /// Writes the chain as PEM.
    static func export(_ chain: [PageInfoCertificate], from window: NSWindow?) {
        guard let first = chain.first else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (first.subject.commonName ?? "certificate").replacingOccurrences(of: "*", with: "_") + ".pem"
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]
        let text = chain.map(\.pem).joined()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

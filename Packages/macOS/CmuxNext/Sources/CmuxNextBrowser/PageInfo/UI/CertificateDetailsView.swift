import AppKit
import CmuxNextDesign

/// The viewer's Details tab: certificate hierarchy (leaf to root), the
/// selected certificate's fields, the selected field's value, and Export.
final class CertificateDetailsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let chain: [PageInfoCertificate]
    private let hierarchy = NSPopUpButton()
    private let table = NSTableView()
    private let valueView = NSTextView()
    private var fields: [(String, String)] = []
    private var scrollFit: ScrollFitElasticity?

    init(chain: [PageInfoCertificate]) {
        self.chain = chain
        super.init(frame: .zero)
        for (depth, certificate) in chain.enumerated() {
            let name = certificate.subject.commonName ?? certificate.subject.organization ?? certificate.serialNumber
            hierarchy.addItem(withTitle: String(repeating: "  ", count: depth) + name)
        }
        hierarchy.target = self
        hierarchy.action = #selector(selectCertificate)

        let column = NSTableColumn(identifier: .init("field"))
        column.title = PageInfoStrings.fields
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        scrollFit = ScrollFitElasticity(scrollView: tableScroll)
        tableScroll.hasVerticalScroller = true
        SystemScrollers.follow(tableScroll)
        tableScroll.drawsBackground = false

        valueView.isEditable = false
        valueView.font = .monospacedSystemFont(ofSize: PageInfoStyle.captionFont.pointSize, weight: .regular)
        valueView.drawsBackground = false
        let valueScroll = NSScrollView()
        valueScroll.documentView = valueView
        valueScroll.hasVerticalScroller = true
        SystemScrollers.follow(valueScroll)
        valueScroll.drawsBackground = false
        valueView.autoresizingMask = [.width]

        let export = NSButton(title: PageInfoStrings.export, target: self, action: #selector(exportChain))
        let views: [NSView] = [
            PageInfoWindow.sectionTitle(PageInfoStrings.hierarchy), hierarchy,
            PageInfoWindow.sectionTitle(PageInfoStrings.fields), tableScroll,
            PageInfoWindow.sectionTitle(PageInfoStrings.fieldValue), valueScroll, export,
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PageInfoStyle.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            hierarchy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            valueScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            valueScroll.heightAnchor.constraint(equalToConstant: 96),
        ])
        selectCertificate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { valueView.textColor = PageInfoStyle.text }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performWithTheme { valueView.textColor = PageInfoStyle.text }
    }

    @objc private func selectCertificate() {
        let index = max(hierarchy.indexOfSelectedItem, 0)
        guard chain.indices.contains(index) else { return }
        fields = Self.fields(of: chain[index])
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showValue()
    }

    @objc private func exportChain() {
        let index = max(hierarchy.indexOfSelectedItem, 0)
        CertificateViewerWindow.export(Array(chain[index...]), from: window)
    }

    static func fields(of certificate: PageInfoCertificate) -> [(String, String)] {
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .long
        return [
            (PageInfoStrings.version, "V\(certificate.version)"),
            (PageInfoStrings.serialNumber, certificate.serialNumber),
            (PageInfoStrings.signatureAlgorithm, certificate.signatureAlgorithm),
            (PageInfoStrings.issuer, certificate.issuer.summary),
            (PageInfoStrings.notBefore, certificate.notBefore.map(dates.string(from:)) ?? ""),
            (PageInfoStrings.notAfter, certificate.notAfter.map(dates.string(from:)) ?? ""),
            (PageInfoStrings.subject, certificate.subject.summary),
            (PageInfoStrings.publicKeyAlgorithm, certificate.publicKeyAlgorithm),
            (PageInfoStrings.alternativeNames, certificate.subjectAlternativeNames.joined(separator: "\n")),
            (PageInfoStrings.sha256Fingerprint, certificate.sha256Fingerprint),
            (PageInfoStrings.sha1Fingerprint, certificate.sha1Fingerprint),
        ].filter { !$0.1.isEmpty }
    }

    private func showValue() {
        let row = table.selectedRow
        valueView.string = fields.indices.contains(row) ? fields[row].1 : ""
    }

    func numberOfRows(in tableView: NSTableView) -> Int { fields.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        PageInfoStyle.label(fields[row].0, font: PageInfoStyle.bodyFont, color: PageInfoStyle.text)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showValue() }
}

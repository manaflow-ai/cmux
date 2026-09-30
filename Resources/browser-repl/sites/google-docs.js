// sites.googleDocs: read and export Google Docs through Google's export
// endpoint in the signed-in session (no tab).
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  S.register(
    "googleDocs",
    (t) => {
      const g = S.shared.google;
      return {
        // { title, text } as Markdown (default), "txt" or "html".
        async read(doc, options = {}) {
          const format = options.format || "md";
          if (!["md", "txt", "html"].includes(format)) throw new S.SiteError("invalid", `googleDocs.read: format: expected md, txt or html, got ${JSON.stringify(format)}`);
          const ref = g.parse(doc, "googleDocs.read", "document");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportText(t, "googleDocs.read", ref, format);
        },
        // Writes the document as md, pdf, docx, txt, html, odt, rtf or epub; { path, title, format }.
        async export(doc, options = {}) {
          const ref = g.parse(doc, "googleDocs.export", "document");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportTo(t, "googleDocs.export", ref, options.format || "md", options);
        },
      };
    },
    { summary: "Read (Markdown/text/HTML) and export (md/pdf/docx/...) Google Docs" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);

// sites.googleDrive: download Drive files and export Google files by URL,
// through Google's download and export endpoints in the signed-in session.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URL, URLSearchParams } = root.CmuxBrowserRepl.core;
  S.register(
    "googleDrive",
    (t) => {
      const g = S.shared.google;
      return {
        // Downloads an uploaded file (PDF, image, zip, ...) by Drive URL or id; { path, title, contentType }.
        async download(file, options = {}) {
          const ref = g.parse(file, "googleDrive.download");
          if (ref.kind && ref.kind !== "file") return g.exportTo(t, "googleDrive.download", ref, options.format || g.FORMATS[ref.kind][0], options);
          const q = new URLSearchParams({ id: ref.id, export: "download", confirm: "t" });
          const uid = options.uid !== undefined ? options.uid : ref.uid;
          if (uid !== undefined) q.set("authuser", String(uid));
          const { response, title, contentType } = await g.fetchFile(t, "googleDrive.download", `https://drive.usercontent.google.com/download?${q}`);
          const fname = g.dispositionName(response.headers.get("content-disposition"));
          const ext = fname && /\.[a-z0-9]{1,8}$/i.test(fname) ? /\.[a-z0-9]{1,8}$/i.exec(fname)[0] : "";
          const file_ = t.outputPath(options, ext, title || `drive-${ref.id}`);
          t.fs.writeFileSync(file_, t.Buffer.from(await response.arrayBuffer()));
          return { path: file_, title, contentType };
        },
        // Exports a Docs/Sheets/Slides file given by any Drive or Docs URL; { path, title, format }.
        async export(file, options = {}) {
          const ref = g.parse(file, "googleDrive.export", options.kind);
          if (ref.kind === "file") throw new S.SiteError("invalid", "googleDrive.export: this is an uploaded Drive file; use googleDrive.download(), or pass { kind: \"document\" | \"spreadsheets\" | \"presentation\" } for a Google file opened by id");
          if (options.uid !== undefined) ref.uid = options.uid;
          return g.exportTo(t, "googleDrive.export", ref, options.format || g.FORMATS[ref.kind][0], options);
        },
      };
    },
    { summary: "Download Drive files; export Google files found by Drive URL" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);

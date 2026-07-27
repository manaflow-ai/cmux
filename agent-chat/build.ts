const out = await Bun.build({
  entrypoints: [`${import.meta.dir}/src/main.tsx`, `${import.meta.dir}/src/gallery-main.tsx`],
  target: "browser",
  minify: true,
  splitting: true,
  outdir: `/tmp/cmux-agent-chat-build-check`,
  define: { "process.env.NODE_ENV": '"production"' },
});

if (!out.success) {
  const msg = out.logs.map((l) => String(l)).join("\n");
  throw new Error("bundle failed:\n" + msg);
}

console.log(`bundle ok (${out.outputs.length} output${out.outputs.length === 1 ? "" : "s"})`);

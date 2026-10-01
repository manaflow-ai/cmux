// Isolated cmux CLI fixture. Never connects to the user's control socket.
const params = JSON.parse(process.argv.at(-1)!);
const child = process.argv.includes("pipe-child");
if (child || params.mode === "ignore-term") {
  process.on("SIGTERM", () => {});
  await Bun.write(params.ready, JSON.stringify({ pid: process.pid }));
  const timer = setInterval(async () => {
    if (await Bun.file(params.exit).exists()) {
      clearInterval(timer);
      await Bun.write(params.done, "done");
      process.exit(0);
    }
  }, 10);
} else if (params.mode === "hold-pipes") {
  Bun.spawn([process.execPath, import.meta.path, "pipe-child", JSON.stringify(params)], {
    stdin: "ignore", stdout: "inherit", stderr: "inherit",
  }).unref();
  process.exit(0);
} else if (params.mode === "json") {
  const bytes = Buffer.from(JSON.stringify({ method: process.argv.at(-2), text: "猫🙂", value: params.value }));
  process.stdout.write(bytes.subarray(0, bytes.indexOf(Buffer.from("猫")) + 1));
  process.stdout.write(bytes.subarray(bytes.indexOf(Buffer.from("猫")) + 1));
} else if (params.mode === "text") {
  process.stdout.write("  plain response\n");
} else if (params.mode === "failure") {
  process.stderr.write("controlled failure ".repeat(40));
  process.exitCode = 7;
}

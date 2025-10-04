import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/vscode")({
  component: VSCodeComponent,
} as const);

function VSCodeComponent() {
  return (
    <div style={{ width: "100vw", height: "100vh", margin: 0, padding: 0, overflow: "hidden" }}>
      <iframe
        src="/vscode.html"
        style={{
          width: "100%",
          height: "100%",
          border: "none",
          margin: 0,
          padding: 0,
        }}
        title="VSCode Web"
      />
    </div>
  );
}
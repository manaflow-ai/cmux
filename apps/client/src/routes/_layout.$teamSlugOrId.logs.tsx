import { ElectronLogsPage } from "@/components/electron-logs/ElectronLogsPage";
import { FloatingPane } from "@/components/floating-pane";
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/_layout/$teamSlugOrId/logs")({
  component: LogsRoute,
});

function LogsRoute() {
  return (
    <FloatingPane>
      <ElectronLogsPage />
    </FloatingPane>
  );
}

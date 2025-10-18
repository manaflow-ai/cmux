import { stackClientApp } from "@/lib/stack";
import { StackHandler } from "@stackframe/react";
import { createFileRoute, useLocation } from "@tanstack/react-router";
import { Suspense } from "react";

export const Route = createFileRoute("/handler/$")({
  component: HandlerComponent,
});

function HandlerComponent() {
  const location = useLocation();

  return (
    <Suspense fallback={null}>
      <StackHandler app={stackClientApp} location={location.pathname} fullPage />
    </Suspense>
  );
}

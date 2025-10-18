import type { ReactNode } from "react";

import { PrReviewClientLayout } from "@/components/pr/pr-review-client-layout";

export default function PrReviewLayout({ children }: { children: ReactNode }) {
  return <PrReviewClientLayout>{children}</PrReviewClientLayout>;
}

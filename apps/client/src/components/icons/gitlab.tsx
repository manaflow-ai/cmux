import type { HTMLAttributes } from "react";

export function GitLabIcon({ className, ...props }: HTMLAttributes<SVGElement>) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" {...props}>
      <path d="M12 21l-7-5 3-9 4 6 4-6 3 9z" fill="currentColor" />
    </svg>
  );
}


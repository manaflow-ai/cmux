'use client';

import { useEffect, useRef } from "react";
import type { ReactNode } from "react";

type LightModeEnforcerProps = {
  children: ReactNode;
};

export function LightModeEnforcer({ children }: LightModeEnforcerProps) {
  const previousClassName = useRef<string | undefined>(undefined);
  const previousDataTheme = useRef<string | undefined>(undefined);

  useEffect(() => {
    const htmlElement = document.documentElement;
    previousClassName.current = htmlElement.className;
    previousDataTheme.current = htmlElement.dataset.theme;

    htmlElement.classList.remove("dark");
    htmlElement.dataset.theme = "light";

    return () => {
      if (previousClassName.current !== undefined) {
        htmlElement.className = previousClassName.current;
      }

      if (previousDataTheme.current === undefined) {
        delete htmlElement.dataset.theme;
      } else {
        htmlElement.dataset.theme = previousDataTheme.current;
      }
    };
  }, []);

  return <>{children}</>;
}

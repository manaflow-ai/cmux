import { Providers } from "./providers";
import { RouterProviderWithAuth } from "./router";

export function App() {
  return (
    <Providers>
      <RouterProviderWithAuth />
    </Providers>
  );
}

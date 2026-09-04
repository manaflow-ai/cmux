package dev.cmux.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.PairedMacStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class StartupViewModel @Inject constructor(
    private val tokenStore: StackAuthTokenStore,
    private val pairedMacStore: PairedMacStore,
) : ViewModel() {

    sealed interface Destination {
        data object Loading : Destination
        data object SignIn : Destination
        data object Pairing : Destination
        data object Workspaces : Destination
    }

    private val _destination = MutableStateFlow<Destination>(Destination.Loading)
    val destination: StateFlow<Destination> = _destination.asStateFlow()

    init {
        viewModelScope.launch {
            _destination.value = when {
                !tokenStore.isSignedIn -> Destination.SignIn
                pairedMacStore.getLatest() != null -> Destination.Workspaces
                else -> Destination.Pairing
            }
        }
    }
}
